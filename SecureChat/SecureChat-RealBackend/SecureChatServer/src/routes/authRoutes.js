'use strict';

const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { validateBundleUpload } = require('../validate');
const { issueToken } = require('../auth');

/**
 * POST /auth/register
 * Body: RegisterRequest { username, bundle: PreKeyBundleUpload }
 * -> AuthToken { userId, token }
 *
 * Matches `APIClientProtocol.register(username:bundle:)`. The bundle's
 * `userId` is client-generated (a fresh UUID), which the client then treats
 * as authoritative — `AuthService.register` compares the server's returned
 * `token.userId` against what it sent and deletes local key material on a
 * mismatch. This server always echoes it back unchanged; it exists as a
 * field at all so a future server implementation (e.g. one that assigns its
 * own ids) has somewhere to diverge without changing the wire shape.
 */
function registerRoute(store, limiters) {
  return async (req, res) => {
    const { rateLimit } = require('../rateLimit');
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

    const existing = store.stmt.accountByUsername.get(body.username);
    if (existing) return sendError(res, 409, 'usernameTaken', 'That username is already taken.');

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
 * POST /auth/login
 * Body: { username }
 * -> AuthToken { userId, token }
 *
 * No password: matches the client's `AuthService.login(username:)`, which
 * authenticates by proving possession of the account's Keychain-resident
 * identity key on a later authenticated call, not at login time. Login here
 * only resolves username -> userId and issues a fresh session token; it is
 * intentionally not the security boundary. See README "Threat model notes"
 * for why this is acceptable for a device-bound scaffold and what you'd add
 * (e.g. requiring the client to sign a server-issued nonce with its identity
 * key) before trusting it for multi-device account recovery.
 */
function loginRoute(store, limiters) {
  return async (req, res) => {
    const { rateLimit } = require('../rateLimit');
    if (!rateLimit(limiters.auth, req, res)) return;

    const body = await readBody(req);
    if (typeof body.username !== 'string') {
      return sendError(res, 400, 'badRequest', 'Missing username');
    }
    const account = store.stmt.accountByUsername.get(body.username);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');

    const token = issueToken(store, account.user_id);
    sendJson(res, 200, { userId: account.user_id, token });
  };
}

module.exports = { registerRoute, loginRoute };
