'use strict';

const { sendJson, sendError, sendNoContent, nowIso } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { issueChallenge, consumeChallenge } = require('../challenge');

/** POST /account/challenge -> { nonce, userId, expiresAt } */
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

/** POST /account/delete { nonce, signature } -> 204 */
function deleteAccountRoute(store, limiters, presence) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    const account = store.stmt.accountById.get(req.userId);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');

    const result = consumeChallenge(store, account, body.nonce, body.signature);
    if (!result.ok) return sendError(res, result.code === 'badRequest' ? 400 : 401, result.code, result.message);

    store.transaction(() => {
      store.stmt.retireUsername.run(account.username, nowIso());
      store.stmt.deletePendingForRecipient.run(account.user_id);
      store.stmt.deletePendingFromSender.run(account.user_id);
      store.stmt.deleteMediaForUploader.run(account.user_id);
      store.stmt.deleteInvitesForUser.run(account.user_id, account.user_id);
      store.stmt.deleteAccountRow.run(account.user_id);
    });
    presence?.disconnect(account.user_id, 4003, 'account deleted');
    presence?.forget(account.user_id);
    sendNoContent(res);
  };
}

module.exports = {
  accountChallengeRoute,
  deleteChallengeRoute: accountChallengeRoute,
  deleteAccountRoute,
};
