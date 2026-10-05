'use strict';

const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { validateBundleUpload } = require('../validate');
const { issueToken } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { issueChallenge, consumeChallenge } = require('../challenge');

/**
 * POST /auth/register  { username, bundle } -> { userId, token }
 */
function registerRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.auth, req, res)) return;

    const body = await readBody(req);
    if (typeof body.username !== 'string' || !body.bundle) {
      return sendError(res, 400, 'badRequest', 'Missing username or bundle');
    }
    const validationError = validateBundleUpload(body.bundle);
    if (validationError) return sendError(res, 400, 'badRequest', validationError);
    if (body.bundle.username !== body.username) {
      return sendError(res, 400, 'badRequest', 'username and bundle.username must match');
    }

    // A deleted account's name is never handed out again: whoever got it
    // would inherit the trust its old contacts placed in that name.
    if (store.stmt.accountByUsername.get(body.username) || store.stmt.isUsernameRetired.get(body.username)) {
      return sendError(res, 409, 'usernameTaken', 'That username is already taken.');
    }
    if (store.stmt.accountById.get(body.bundle.userId)) {
      return sendError(res, 409, 'usernameTaken', 'That account id is already in use.');
    }

    try {
      store.transaction(() => {
        store.stmt.insertAccount.run(
          body.bundle.userId,
          body.bundle.username,
          body.bundle.identityAgreementKey,
          body.bundle.identitySigningKey,
          body.bundle.signedPreKeyId,
          body.bundle.signedPreKey,
          body.bundle.signedPreKeySignature,
          nowIso(),
        );
        for (const otk of body.bundle.oneTimePreKeys) {
          store.stmt.insertOneTimePreKey.run(body.bundle.userId, otk.id, otk.publicKey);
        }
      });
    } catch (err) {
      if (String(err.message).includes('UNIQUE')) {
        return sendError(res, 409, 'usernameTaken', 'That username is already taken.');
      }
      throw err;
    }

    const token = issueToken(store, body.bundle.userId);
    sendJson(res, 201, { userId: body.bundle.userId, token });
  };
}

/**
 * POST /auth/login/challenge  { username } -> { nonce, userId, expiresAt }
 */
function loginChallengeRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    if (typeof body.username !== 'string') {
      return sendError(res, 400, 'badRequest', 'Missing username');
    }
    const account = store.stmt.accountByUsername.get(body.username);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');
    sendJson(res, 200, issueChallenge(store, account));
  };
}

/**
 * POST /auth/login  { username, nonce, signature } -> { userId, token }
 */
function loginRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    if (typeof body.username !== 'string') {
      return sendError(res, 400, 'badRequest', 'Missing username, nonce, or signature');
    }
    const account = store.stmt.accountByUsername.get(body.username);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');

    const result = consumeChallenge(store, account, body.nonce, body.signature);
    if (!result.ok) {
      return sendError(res, result.code === 'badRequest' ? 400 : 401, result.code, result.message);
    }
    const token = issueToken(store, account.user_id);
    sendJson(res, 200, { userId: account.user_id, token });
  };
}

module.exports = { registerRoute, loginChallengeRoute, loginRoute };
