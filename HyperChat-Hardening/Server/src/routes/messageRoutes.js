'use strict';

const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { validateEnvelope, normalizeEnvelope, isValidOpaqueId } = require('../validate');
const { rowToEnvelopeDTO } = require('../envelopeMapper');
const { pushForEnvelope } = require('../apns');

const DEFAULT_PAGE_SIZE = 200;
const MAX_ACK_IDS = 500;
const INVITES_PER_DAY = 20;

/** One recipient's queue can't be filled to the brim by a single sender. */
const maxPendingPerRecipient = () => Number(process.env.MAX_PENDING_PER_RECIPIENT) || 10_000;
const maxPendingPerSender = () => Number(process.env.MAX_PENDING_PER_SENDER) || 2_000;

/**
 * POST /messages
 * `req.userId` must equal `body.senderId` — you can only send as yourself.
 * -> 202 { accepted: true }
 *
 * The envelope is written to the recipient's durable queue first, then pushed
 * live if they're connected: the queue is the source of truth, the push only a
 * latency shortcut on top.
 *
 * A RETRY of an envelope already stored is acknowledged but NOT pushed again.
 * `INSERT OR IGNORE ... RETURNING` yields no row for a retry; the old code
 * ignored that and fired APNs, ntfy and the live socket a second time.
 */
function sendMessageRoute(store, limiters, presence, apns, ntfy) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.messages, req, res)) return;

    const body = await readBody(req);
    const validationError = validateEnvelope(body);
    if (validationError) return sendError(res, 400, 'badRequest', validationError);
    if (body.senderId !== req.userId) {
      return sendError(res, 403, 'forbidden', 'Cannot send as another account');
    }
    if (body.recipientId === body.senderId) {
      return sendError(res, 400, 'badRequest', 'Cannot send to yourself');
    }
    if (!store.stmt.accountById.get(body.recipientId)) {
      return sendError(res, 404, 'userNotFound', 'No such recipient.');
    }

    const envelope = normalizeEnvelope(body);

    // `ack` removes by (recipient, envelope id); another sender's message must
    // never share that id.
    if (store.stmt.envelopeIdClash.get(envelope.recipientId, envelope.id, envelope.senderId)) {
      return sendError(res, 409, 'conflict', 'Envelope id already in use.');
    }

    if (store.stmt.pendingCountFromSender.get(envelope.recipientId, envelope.senderId).n >= maxPendingPerSender()
        || store.stmt.pendingCountForUser.get(envelope.recipientId).n >= maxPendingPerRecipient()) {
      return sendError(res, 429, 'recipientQueueFull', 'The recipient has too many undelivered messages.');
    }

    if (envelope.contentType === 'invite') {
      const dayAgo = new Date(Date.now() - 86_400_000).toISOString();
      if (store.stmt.countInvitesSince.get(envelope.senderId, dayAgo).n >= INVITES_PER_DAY) {
        return sendError(res, 429, 'rateLimited', 'Too many invitations today.');
      }
    }

    // The invite record and the queued envelope are one unit.
    const stored = store.transaction(() => {
      if (envelope.contentType === 'invite') {
        store.stmt.upsertInvite.run(envelope.senderId, envelope.recipientId, nowIso());
      }
      return store.stmt.insertPendingEnvelope.get(
        envelope.id,
        envelope.conversationId,
        envelope.senderId,
        envelope.recipientId,
        envelope.kind,
        envelope.handshake ? JSON.stringify(envelope.handshake) : null,
        envelope.ratchetMessage,
        envelope.contentType,
        envelope.createdAt,
        nowIso(),
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

/**
 * GET /messages/pending?since=<cursor>
 * The recipient is always `req.userId` from the token, never a client-supplied
 * id. `since` is the server-assigned `sequence`, not a timestamp (two envelopes
 * can share a sender-supplied createdAt).
 */
function fetchPendingRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.messages, req, res)) return;

    const parsed = Number(req.query.get('since'));
    const since = Number.isFinite(parsed) ? Math.max(0, Math.floor(parsed)) : 0;
    const rows = store.stmt.pendingSince.all(req.userId, since, DEFAULT_PAGE_SIZE);
    const envelopes = rows.map(rowToEnvelopeDTO);
    const cursor = rows.length > 0 ? rows[rows.length - 1].sequence : since;
    sendJson(res, 200, { envelopes, cursor });
  };
}

/** GET /messages?conversationId=<id> — still-pending envelopes for one thread. */
function fetchByConversationRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.messages, req, res)) return;
    const conversationId = req.query.get('conversationId');
    if (!isValidOpaqueId(conversationId)) return sendError(res, 400, 'badRequest', 'invalid conversationId');
    const rows = store.stmt.pendingByConversation.all(req.userId, conversationId);
    sendJson(res, 200, rows.map(rowToEnvelopeDTO));
  };
}

/**
 * POST /messages/ack  { envelopeIds: [String] } -> 204
 * A client can only ever acknowledge its own queue. At most 500 ids per call.
 */
function acknowledgeRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.messages, req, res)) return;
    const body = await readBody(req);
    if (!Array.isArray(body.envelopeIds)) {
      return sendError(res, 400, 'badRequest', 'envelopeIds must be an array');
    }
    if (body.envelopeIds.length > MAX_ACK_IDS) {
      return sendError(res, 400, 'badRequest', `At most ${MAX_ACK_IDS} ids per request`);
    }
    store.transaction(() => {
      for (const id of body.envelopeIds) {
        if (isValidOpaqueId(id)) store.stmt.ackEnvelope.run(req.userId, id);
      }
    });
    res.writeHead(204).end();
  };
}

module.exports = { sendMessageRoute, fetchPendingRoute, fetchByConversationRoute, acknowledgeRoute };
