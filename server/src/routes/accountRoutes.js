'use strict';

const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { issueChallenge, consumeChallenge } = require('../challenge');

const TOKEN_RE = /^[0-9a-fA-F]{64,200}$/;

/**
 * POST /account/challenge  (also served at /account/delete/challenge, the path
 * older app versions use) -> { nonce, userId, expiresAt }
 *
 * A single-use nonce the device signs with its identity key to prove it holds
 * the keys — required for deleting the account and for changing the recovery
 * email, so a leaked bearer token alone isn't enough.
 */
function accountChallengeRoute(store, limiters) {
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
 * Removes everything the server holds for this user — including the files they
 * uploaded — and retires the username so it is never reissued.
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
      store.stmt.deleteMediaForUploader.run(account.user_id);
      store.stmt.deleteInvitesForUser.run(account.user_id, account.user_id);
      // Cascades: prekeys, sessions, challenges, email, codes, tickets, backup,
      // device tokens, ntfy topic.
      store.stmt.deleteAccountRow.run(account.user_id);
    });

    // Public methods — this used to reach into `presence.connections` directly.
    presence?.disconnect(account.user_id, 4003, 'account deleted');
    presence?.forget(account.user_id);
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
    // Upsert by token: a token moves to whoever signed in on that device last, so
    // a logged-out account stops getting this phone's notifications.
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

module.exports = {
  accountChallengeRoute,
  deleteChallengeRoute: accountChallengeRoute, // kept for the existing name
  deleteAccountRoute,
  registerPushTokenRoute,
  removePushTokenRoute,
};
