'use strict';

const { sendJson, sendError, sendNoContent, nowIso } = require('../json');
const { readBody } = require('../router');
const { validateBundleUpload } = require('../validate');
const { issueToken, resolveToken, revokeToken, extractBearerToken } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { issueChallenge, decoyChallenge, consumeChallenge } = require('../challenge');
const { serverSecret } = require('../secret');

/**
 * POST /auth/register  { username, bundle } -> { userId, token }
 * FIX (S15): its own bucket, 5 registrations per IP per hour — registration is
 * open, and every account is another sender for spam.
 */
function registerRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.register, req, res)) return;
    const body = await readBody(req);
    if (typeof body.username !== 'string' || !body.bundle) {
      return sendError(res, 400, 'badRequest', 'Missing username or bundle');
    }
    const validationError = validateBundleUpload(body.bundle);
    if (validationError) return sendError(res, 400, 'badRequest', validationError);
    if (body.bundle.username !== body.username) {
      return sendError(res, 400, 'badRequest', 'username and bundle.username must match');
    }
    if (store.stmt.accountByUsername.get(body.username) || store.stmt.isUsernameRetired.get(body.username)) {
      return sendError(res, 409, 'usernameTaken', 'That username is already taken.');
    }
    if (store.stmt.accountById.get(body.bundle.userId)) {
      return sendError(res, 409, 'usernameTaken', 'That account id is already in use.');
    }

    try {
      store.transaction(() => {
        store.stmt.insertAccount.run(
          body.bundle.userId, body.bundle.username,
          body.bundle.identityAgreementKey, body.bundle.identitySigningKey,
          body.bundle.signedPreKeyId, body.bundle.signedPreKey, body.bundle.signedPreKeySignature,
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
 * FIX (S21): an unknown username gets a decoy challenge instead of 404, so this
 * unauthenticated endpoint no longer lists which usernames exist.
 */
function loginChallengeRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.login, req, res)) return;
    const body = await readBody(req);
    if (typeof body.username !== 'string' || body.username.length > 64) {
      return sendError(res, 400, 'badRequest', 'Missing username');
    }
    const account = store.stmt.accountByUsername.get(body.username);
    if (!account) return sendJson(res, 200, decoyChallenge(body.username, serverSecret()));
    sendJson(res, 200, issueChallenge(store, account));
  };
}

/** POST /auth/login  { username, nonce, signature } -> { userId, token } */
function loginRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.login, req, res)) return;
    const body = await readBody(req);
    if (typeof body.username !== 'string') {
      return sendError(res, 400, 'badRequest', 'Missing username, nonce, or signature');
    }
    const account = store.stmt.accountByUsername.get(body.username);
    // Same answer for "no such user" and "bad challenge" (S21).
    const result = consumeChallenge(store, account, body.nonce, body.signature);
    if (!result.ok) {
      return sendError(res, result.code === 'badRequest' ? 400 : 401, result.code, result.message);
    }
    const token = issueToken(store, account.user_id);
    sendJson(res, 200, { userId: account.user_id, token });
  };
}

/** POST /auth/logout -> 204 (idempotent). */
function logoutRoute(store) {
  return async (req, res) => {
    const token = extractBearerToken(req);
    if (resolveToken(store, token)) revokeToken(store, token);
    sendNoContent(res);
  };
}

module.exports = { registerRoute, loginChallengeRoute, loginRoute, logoutRoute };
