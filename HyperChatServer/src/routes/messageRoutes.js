'use strict';

const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { validateEnvelope } = require('../validate');
const { rowToEnvelopeDTO } = require('../envelopeMapper');

const DEFAULT_PAGE_SIZE = 200;

/**
 * POST /messages
 * Auth required. `req.userId` must equal `body.senderId` — you can only send
 * as yourself. Body: EnvelopeDTO.
 * -> 202 { accepted: true }
 *
 * Writes the envelope to the recipient's durable queue first, then attempts
 * a live push if they're connected (see `presence.js`). That order matters:
 * if the push happened first and the durable write failed afterwards, a
 * connected-but-slow recipient could see the message once over the socket
 * and then lose it forever if they reconnect before acknowledging — the
 * queue has to be the source of truth, the push is only ever a latency
 * shortcut on top of it.
 *
 * `INSERT OR IGNORE ... ON CONFLICT (recipient_id, sender_id, envelope_id)`
 * makes a resent envelope (e.g. the client retrying after a dropped
 * response) idempotent server-side too, on top of the client's own replay
 * protection.
 */
function sendMessageRoute(store, limiters, presence) {
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

      const recipient = store.stmt.accountById.get(body.recipientId);

      if (!recipient) {
          return sendError(res, 404, 'userNotFound', 'No such recipient.');
      }

      if (body.contentType === 'invite') {
          const dayAgo = new Date(
              Date.now() - 86_400_000
          ).toISOString();

          const sentToday =
              store.stmt.countInvitesSince.get(
                  body.senderId,
                  dayAgo
              ).n;

          if (sentToday >= 20) {
              return sendError(
                  res,
                  429,
                  'rateLimited',
                  'Too many invitations today.'
              );
          }

          store.stmt.upsertInvite.run(
              body.senderId,
              body.recipientId,
              nowIso()
          );
      }

      const createdAt = body.createdAt || nowIso();
    store.stmt.insertPendingEnvelope.get(
      body.id,
      body.conversationId,
      body.senderId,
      body.recipientId,
      body.kind,
      body.handshake ? JSON.stringify(body.handshake) : null,
      body.ratchetMessage,
      body.contentType,
      createdAt,
    );

    presence.push(body.recipientId, { ...body, createdAt });
    sendJson(res, 202, { accepted: true });
  };
}

/**
 * GET /messages/pending?since=<cursor>
 * Auth required. Recipient is always `req.userId` from the token — never a
 * client-supplied id — so one account can never drain another account's
 * queue by guessing a `userId` query parameter.
 * -> PendingEnvelopesPage { envelopes: [EnvelopeDTO], cursor }
 *
 * `since` is the server-assigned `sequence` counter, not a timestamp: two
 * envelopes can share a `createdAt` (it's sender-supplied), so a
 * timestamp-based cursor could resume at the wrong boundary and either
 * re-deliver or silently skip one. `cursor` in the response is always the
 * sequence of the last row in this page (or the input cursor unchanged if
 * there were no rows), matching what `MessagingService.backfillPendingEnvelopes`
 * expects to persist via `SyncCursorStore`.
 */
function fetchPendingRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.messages, req, res)) return;

    const sinceParam = req.query.get('since');
    const since = Number.isFinite(Number(sinceParam)) ? Number(sinceParam) : 0;
    const rows = store.stmt.pendingSince.all(req.userId, since, DEFAULT_PAGE_SIZE);

    const envelopes = rows.map(rowToEnvelopeDTO);
    const cursor = rows.length > 0 ? rows[rows.length - 1].sequence : since;
    sendJson(res, 200, { envelopes, cursor });
  };
}

/**
 * GET /messages?conversationId=<id>
 * Auth required. Legacy/optional path matching
 * `APIClientProtocol.fetchEnvelopes(conversationId:)`.
 *
 * Deliberately returns only *still-pending* (not yet acknowledged) envelopes
 * for this conversation, scoped to `req.userId` as recipient — there is no
 * separate permanent per-conversation archive on the server (see the note
 * on `pending_envelopes` in db.js for why). A client that wants full history
 * should rely on its own local, already-decrypted store; this endpoint is
 * only useful for "what haven't I picked up yet for this specific thread".
 */
function fetchByConversationRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.messages, req, res)) return;

    const conversationId = req.query.get('conversationId');
    if (!conversationId) return sendError(res, 400, 'badRequest', 'missing conversationId');

    const rows = store.stmt.pendingByConversation.all(req.userId, conversationId);
    sendJson(res, 200, rows.map(rowToEnvelopeDTO));
  };
}

/**
 * POST /messages/ack
 * Auth required. Body: { envelopeIds: [String] }
 * -> 204
 *
 * Matches `APIClientProtocol.acknowledge(userId:envelopeIds:)`. Deletes rows
 * scoped to `(recipientId = req.userId, envelope_id IN (...))` — a client
 * can only ever acknowledge its own queue, never another account's.
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
    store.transaction(() => {
      for (const id of body.envelopeIds) {
        if (typeof id === 'string') store.stmt.ackEnvelope.run(req.userId, id);
      }
    });
    res.writeHead(204).end();
  };
}

module.exports = { sendMessageRoute, fetchPendingRoute, fetchByConversationRoute, acknowledgeRoute };
