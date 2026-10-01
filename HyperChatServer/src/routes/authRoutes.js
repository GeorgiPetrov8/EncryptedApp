'use strict';

const crypto = require('node:crypto');

const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { validateBundleUpload } = require('../validate');
const { issueToken } = require('../auth');

const LOGIN_CHALLENGE_TTL_MS = 60 * 1000;

function toSpkiEd25519(rawPublicKey) {
    const key = Buffer.from(rawPublicKey, 'base64');

    // DER SubjectPublicKeyInfo prefix for Ed25519.
    const prefix = Buffer.from('302a300506032b6570032100', 'hex');

    return Buffer.concat([prefix, key]);
}

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
      
  const existingUserId = store.stmt.accountById.get(body.bundle.userId);

  if (existingUserId) {
      return sendError(
          res,
          409,
          'usernameTaken',
          'That account id is already in use.'
      );
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

function loginChallengeRoute(store, limiters) {
    return async (req, res) => {
        const { rateLimit } = require('../rateLimit');
        if (!rateLimit(limiters.auth, req, res)) return;

        const body = await readBody(req);

        if (typeof body.username !== 'string') {
            return sendError(res, 400, 'badRequest', 'Missing username');
        }

        const account = store.stmt.accountByUsername.get(body.username);

        if (!account) {
            return sendError(res, 404, 'userNotFound', 'No such user.');
        }

        // Remove expired challenges first.
        store.stmt.deleteExpiredLoginChallenges.run(nowIso());

        const nonce = crypto.randomBytes(32).toString('base64');
        const nonceHash = crypto
            .createHash('sha256')
            .update(nonce, 'utf8')
            .digest('hex');

        const createdAt = new Date();
        const expiresAt = new Date(
            createdAt.getTime() + LOGIN_CHALLENGE_TTL_MS
        );

        store.stmt.insertLoginChallenge.run(
            nonceHash,
            account.user_id,
            createdAt.toISOString(),
            expiresAt.toISOString()
        );

        sendJson(res, 200, {
            nonce,
            expiresAt: expiresAt.toISOString(),
        });
    };
}
/**
 * POST /auth/login
 * Body: { username, nonce, signature }
 * -> AuthToken { userId, token }
 *
 * The client proves possession of the account's Ed25519
 * identity signing key by signing the server-issued nonce.
 */
function loginRoute(store, limiters) {
    return async (req, res) => {
        const { rateLimit } = require('../rateLimit');
        if (!rateLimit(limiters.auth, req, res)) return;

        const body = await readBody(req);

        if (
            typeof body.username !== 'string' ||
            typeof body.nonce !== 'string' ||
            typeof body.signature !== 'string'
        ) {
            return sendError(
                res,
                400,
                'badRequest',
                'Missing username, nonce, or signature'
            );
        }

        const account = store.stmt.accountByUsername.get(body.username);

        if (!account) {
            return sendError(
                res,
                404,
                'userNotFound',
                'No such user.'
            );
        }

        const nonceHash = crypto
            .createHash('sha256')
            .update(body.nonce, 'utf8')
            .digest('hex');

        const challenge =
            store.stmt.loginChallengeByHash.get(nonceHash);

        if (!challenge) {
            return sendError(
                res,
                401,
                'invalidChallenge',
                'Invalid or expired login challenge.'
            );
        }

        if (challenge.user_id !== account.user_id) {
            return sendError(
                res,
                401,
                'invalidChallenge',
                'Invalid login challenge.'
            );
        }

        if (new Date(challenge.expires_at).getTime() < Date.now()) {
            store.stmt.deleteLoginChallenge.run(nonceHash);

            return sendError(
                res,
                401,
                'invalidChallenge',
                'Login challenge has expired.'
            );
        }

        let signature;

        try {
            signature = Buffer.from(body.signature, 'base64');

            if (signature.length !== 64) {
                return sendError(
                    res,
                    401,
                    'invalidSignature',
                    'Invalid signature.'
                );
            }
        } catch {
            return sendError(
                res,
                401,
                'invalidSignature',
                'Invalid signature.'
            );
        }

        let publicKey;

        try {
            publicKey = toSpkiEd25519(account.identity_signing_key);
        } catch {
            return sendError(
                res,
                500,
                'serverError',
                'Invalid stored identity key.'
            );
        }

        const valid = crypto.verify(
            null,
            Buffer.from(body.nonce, 'base64'),
            {
                key: publicKey,
                format: 'der',
                type: 'spki',
            },
            signature
        );

        if (!valid) {
            return sendError(
                res,
                401,
                'invalidSignature',
                'Invalid login signature.'
            );
        }

        // Single-use challenge: delete it before issuing the token.
        store.stmt.deleteLoginChallenge.run(nonceHash);

        const token = issueToken(store, account.user_id);

        sendJson(res, 200, {
            userId: account.user_id,
            token,
        });
    };
}

module.exports = {
    registerRoute,
    loginChallengeRoute,
    loginRoute,
};
