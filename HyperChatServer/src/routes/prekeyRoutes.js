'use strict';

const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { validateSignedPreKeyUpload, validateOneTimePreKeyBatch, isValidUsername, isValidUserId } = require('../validate');

function directoryEntryFromAccountRow(row) {
  return {
    userId: row.user_id,
    username: row.username,
    identityAgreementKey: row.identity_agreement_key,
    identitySigningKey: row.identity_signing_key,
  };
}

/**
 * POST /prekeys/one-time
 * Auth required. Body: { userId, keys: [{ id, publicKey }] }
 * -> 204
 *
 * Matches `APIClientProtocol.replenishOneTimePreKeys`. `req.userId` (from the
 * bearer token) must equal the `userId` in the body — nobody may top up
 * someone else's prekey pool, which would otherwise let an attacker exhaust
 * a victim's *id space* by pre-filling it with keys they hold the private
 * half of, undermining forward secrecy for that victim's future handshakes.
 */
function replenishOneTimePreKeysRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.prekeys, req, res)) return;

    const body = await readBody(req);
    if (body.userId !== req.userId) {
      return sendError(res, 403, 'forbidden', 'Cannot modify another account\'s prekeys');
    }
    const validationError = validateOneTimePreKeyBatch(body);
    if (validationError) return sendError(res, 400, 'badRequest', validationError);

    store.transaction(() => {
      for (const otk of body.keys) {
        store.stmt.insertOneTimePreKey.run(req.userId, otk.id, otk.publicKey);
      }
    });
    res.writeHead(204).end();
  };
}

/**
 * POST /prekeys/signed
 * Auth required. Body: SignedPreKeyUpload
 * -> 204
 *
 * Matches `APIClientProtocol.publishSignedPreKey`. Overwrites the account's
 * advertised signed prekey; the client is responsible for retaining the
 * previous private key locally through its grace period (see
 * `CryptoService.rotateSignedPreKey`) so in-flight handshakes against the
 * old id still resolve — the server only ever needs to know the current one.
 */
function publishSignedPreKeyRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.prekeys, req, res)) return;

    const body = await readBody(req);
    if (body.userId !== req.userId) {
      return sendError(res, 403, 'forbidden', 'Cannot modify another account\'s prekeys');
    }
    const validationError = validateSignedPreKeyUpload(body);
    if (validationError) return sendError(res, 400, 'badRequest', validationError);

    const result = store.stmt.updateSignedPreKey.run(
      body.signedPreKeyId, body.signedPreKey, body.signedPreKeySignature, req.userId,
    );
    if (result.changes === 0) return sendError(res, 404, 'userNotFound', 'No such user.');
    res.writeHead(204).end();
  };
}

/**
 * GET /directory/by-id/:userId
 * GET /directory/by-username/:username
 * Auth required (any valid session — this does not require the caller to
 * already know the target, only to be a real account, which keeps the
 * directory from being scraped anonymously).
 * -> DirectoryEntry
 *
 * The non-destructive lookup: unlike /bundles/*, this never touches the
 * one-time prekey pool. It exists so a display-name lookup (see
 * `MessagingService.ensureContact`'s fallback path) can't burn a prekey
 * reserved for an actual X3DH handshake.
 */
function directoryByIdRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.directory, req, res)) return;
    if (!isValidUserId(req.params.userId)) return sendError(res, 400, 'badRequest', 'invalid userId');

    const account = store.stmt.accountById.get(req.params.userId);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');
    sendJson(res, 200, directoryEntryFromAccountRow(account));
  };
}

function directoryByUsernameRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.directory, req, res)) return;
    if (!isValidUsername(req.params.username)) return sendError(res, 400, 'badRequest', 'invalid username');

    const account = store.stmt.accountByUsername.get(req.params.username);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');
    sendJson(res, 200, directoryEntryFromAccountRow(account));
  };
}

/**
 * GET /bundles/by-id/:userId
 * GET /bundles/by-username/:username
 * Auth required.
 * -> PreKeyBundle (with at most one one-time prekey, popped from the pool)
 *
 * Matches `APIClientProtocol.fetchPreKeyBundle`. Each call consumes one
 * one-time prekey for the target account, atomically (see
 * `db.stmt.popOneTimePreKey`'s `DELETE ... RETURNING`) — two concurrent
 * callers can never receive the same one-time prekey. When the pool is
 * empty, `oneTimePreKeyId`/`oneTimePreKey` are `null`; the client's `X3DH`
 * already handles that by skipping dh4 on both sides.
 */
function bundleByIdRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.prekeys, req, res)) return;
    if (!isValidUserId(req.params.userId)) return sendError(res, 400, 'badRequest', 'invalid userId');

    const account = store.stmt.accountById.get(req.params.userId);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');
    sendJson(res, 200, issueBundle(store, account));
  };
}

function bundleByUsernameRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.prekeys, req, res)) return;
    if (!isValidUsername(req.params.username)) return sendError(res, 400, 'badRequest', 'invalid username');

    const account = store.stmt.accountByUsername.get(req.params.username);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');
    sendJson(res, 200, issueBundle(store, account));
  };
}

function issueBundle(store, account) {
  const popped = store.stmt.popOneTimePreKey.get(account.user_id, account.user_id);
  return {
    userId: account.user_id,
    username: account.username,
    identityAgreementKey: account.identity_agreement_key,
    identitySigningKey: account.identity_signing_key,
    signedPreKeyId: account.signed_prekey_id,
    signedPreKey: account.signed_prekey,
    signedPreKeySignature: account.signed_prekey_signature,
    oneTimePreKeyId: popped ? popped.prekey_id : null,
    oneTimePreKey: popped ? popped.public_key : null,
  };
}

module.exports = {
  replenishOneTimePreKeysRoute,
  publishSignedPreKeyRoute,
  directoryByIdRoute,
  directoryByUsernameRoute,
  bundleByIdRoute,
  bundleByUsernameRoute,
};
