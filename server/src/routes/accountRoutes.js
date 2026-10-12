'use strict';

const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { issueChallenge, consumeChallenge } = require('../challenge');

const TOKEN_RE = /^[0-9a-fA-F]{64,200}$/;

/** POST /account/delete/challenge -> { nonce, userId, expiresAt } */
function deleteChallengeRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.auth, req, res)) return;
    const account = store.stmt.accountById.get(req.userId);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');
    sendJson(res, 200, issueChallenge(store, account));
  };
}

/**
 * POST /account/delete { nonce, signature } -> 204
 *
 * Needs the bearer token AND a signature from the identity key, so a leaked
 * token alone can't destroy an account. Removes everything the server holds
 * for this user; the username is retired, never reissued.
 */
function deleteAccountRoute(store, limiters, presence) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    const account = store.stmt.accountById.get(req.userId);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');

    const result = consumeChallenge(store, account, body.nonce, body.signature);
    if (!result.ok) {
      return sendError(res, result.code === 'badRequest' ? 400 : 401, result.code, result.message);
    }

    store.transaction(() => {
      store.stmt.retireUsername.run(account.username, nowIso());
      store.stmt.deletePendingForRecipient.run(account.user_id);
      // Undelivered messages this user sent are withdrawn too.
      store.stmt.deletePendingFromSender.run(account.user_id);
      store.stmt.deleteInvitesForUser.run(account.user_id, account.user_id);
      store.stmt.deleteAccountRow.run(account.user_id);
    });

    if (presence) {
      presence.connections?.get(account.user_id)?.close(4003, 'account deleted');
      presence.forget?.(account.user_id);
    }
    res.writeHead(204).end();
  };
}

/** POST /devices/push-token { token, environment } -> 204 */
function registerPushTokenRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.prekeys, req, res)) return;
    const body = await readBody(req);
    if (typeof body.token !== 'string' || !TOKEN_RE.test(body.token)) {
      return sendError(res, 400, 'badRequest', 'invalid token');
    }
    const environment = body.environment === 'sandbox' ? 'sandbox' : 'production';
    // Upsert by token: a token moves to whoever signed in on that device last,
    // so a logged-out account stops getting this phone's notifications.
    store.stmt.upsertDeviceToken.run(body.token.toLowerCase(), req.userId, environment, nowIso());
    res.writeHead(204).end();
  };
}

/** POST /devices/push-token/remove { token } -> 204  (on logout) */
function removePushTokenRoute(store) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    const body = await readBody(req);
    if (typeof body.token === 'string') {
      store.stmt.deleteDeviceTokenForUser.run(body.token.toLowerCase(), req.userId);
    }
    res.writeHead(204).end();
  };
}

module.exports = { deleteChallengeRoute, deleteAccountRoute, registerPushTokenRoute, removePushTokenRoute };
