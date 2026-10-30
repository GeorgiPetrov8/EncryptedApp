'use strict';

const { sendJson, sendError, sendNoContent, nowIso } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { validateEnvelope, normalizeEnvelope, isValidOpaqueId } = require('../validate');
const { rowToEnvelopeDTO } = require('../envelopeMapper');
const { pushForEnvelope } = require('../apns');

const DEFAULT_PAGE_SIZE = 200;
const MAX_ACK_IDS = 500;
const INVITES_PER_DAY = 20;

const maxPendingPerRecipient = () => Number(process.env.MAX_PENDING_PER_RECIPIENT) || 10_000;
const maxPendingPerSender = () => Number(process.env.MAX_PENDING_PER_SENDER) || 2_000;
/** S15: on by default; set REQUIRE_RELATIONSHIP=0 only to debug an old database. */
const requireRelationship = () => process.env.REQUIRE_RELATIONSHIP !== '0';

/**
 * POST /messages -> 202 { accepted: true }
 *
 * FIX (S15): anything other than an invitation is only accepted between two
 * people who have an invitation between them (either direction). A stranger can
 * send at most an invitation (20 a day) — not a flood of messages, call signals
 * or profile pictures into someone's queue.
 *
 * FIX (S1): a handshake's `senderUsername` is overwritten with the sender's
 * registered username.
 */
function sendMessageRoute(store, limiters, presence, apns, ntfy) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.messages, req, res)) return;

    const body = await readBody(req);
    const validationError = validateEnvelope(body);
    if (validationError) return sendError(res, 400, 'badRequest', validationError);
    if (body.senderId !== req.userId) return sendError(res, 403, 'forbidden', 'Cannot send as another account');
    if (body.recipientId === body.senderId) return sendError(res, 400, 'badRequest', 'Cannot send to yourself');
    if (!store.stmt.accountById.get(body.recipientId)) return sendError(res, 404, 'userNotFound', 'No such recipient.');

    if (body.contentType !== 'invite' && requireRelationship()
        && !store.stmt.hasRelationship.get(body.senderId, body.recipientId, body.recipientId, body.senderId)) {
      return sendError(res, 403, 'notConnected', 'Invite this person first.');
    }

    const sender = store.stmt.accountById.get(body.senderId);
    const envelope = normalizeEnvelope(body, { senderUsername: sender?.username });

    if (store.stmt.envelopeIdClash.get(envelope.recipientId, envelope.id, envelope.senderId)) {
      return sendError(res, 409, 'conflict', 'Envelope id already in use.');
    }
    if (store.stmt.pendingCountFromSender.get(envelope.recipientId, envelope.senderId).n >= maxPendingPerSender()
        || store.stmt.pendingCountForUser.get(envelope.recipientId).n >= maxPendingPerRecipient()) {
      return sendError(res, 429, 'recipientQueueFull', 'The recipient has too many undelivered messages.');
    }
    if (envelope.contentType === 'invite') {
      const dayAgo = new Date(Date.now() - 86_400_000).toISOString();
      const existing = store.stmt.hasRelationship.get(envelope.senderId, envelope.recipientId, envelope.recipientId, envelope.senderId);
      if (!existing && store.stmt.countInvitesSince.get(envelope.senderId, dayAgo).n >= INVITES_PER_DAY) {
        return sendError(res, 429, 'rateLimited', 'Too many invitations today.');
      }
    }

    const stored = store.transaction(() => {
      if (envelope.contentType === 'invite') {
        store.stmt.upsertInvite.run(envelope.senderId, envelope.recipientId, nowIso());
      }
      return store.stmt.insertPendingEnvelope.get(
        envelope.id, envelope.conversationId, envelope.senderId, envelope.recipientId, envelope.kind,
        envelope.handshake ? JSON.stringify(envelope.handshake) : null,
        envelope.ratchetMessage, envelope.contentType, envelope.createdAt, nowIso(),
      );
    });

    if (stored) {
      pushForEnvelope({ apns, store, presence, envelope }).catch(() => {});
      ntfy.notifyForEnvelope(envelope, presence).catch(() => {});
      presence.push(envelope.recipientId, envelope);
    }
    sendJson(res, 202, { accepted: true });
  };
}

function fetchPendingRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.messages, req, res)) return;
    const parsed = Number(req.query.get('since'));
    const since = Number.isFinite(parsed) ? Math.max(0, Math.floor(parsed)) : 0;
    const rows = store.stmt.pendingSince.all(req.userId, since, DEFAULT_PAGE_SIZE);
    const cursor = rows.length > 0 ? rows[rows.length - 1].sequence : since;
    sendJson(res, 200, { envelopes: rows.map(rowToEnvelopeDTO), cursor });
  };
}

function fetchByConversationRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.messages, req, res)) return;
    const conversationId = req.query.get('conversationId');
    if (!isValidOpaqueId(conversationId)) return sendError(res, 400, 'badRequest', 'invalid conversationId');
    sendJson(res, 200, store.stmt.pendingByConversation.all(req.userId, conversationId).map(rowToEnvelopeDTO));
  };
}

function acknowledgeRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.messages, req, res)) return;
    const body = await readBody(req);
    if (!Array.isArray(body.envelopeIds)) return sendError(res, 400, 'badRequest', 'envelopeIds must be an array');
    if (body.envelopeIds.length > MAX_ACK_IDS) return sendError(res, 400, 'badRequest', `At most ${MAX_ACK_IDS} ids per request`);
    store.transaction(() => {
      for (const id of body.envelopeIds) {
        if (isValidOpaqueId(id)) store.stmt.ackEnvelope.run(req.userId, id);
      }
    });
    sendNoContent(res);
  };
}

module.exports = { sendMessageRoute, fetchPendingRoute, fetchByConversationRoute, acknowledgeRoute };
