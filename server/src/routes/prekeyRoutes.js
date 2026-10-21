'use strict';

const { sendJson, sendError } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const {
  validateSignedPreKeyUpload, validateOneTimePreKeyBatch, isValidUsername, isValidUserId,
} = require('../validate');

/** An account never holds more than this many unused one-time prekeys on the server. */
const MAX_ONE_TIME_PREKEYS = 200;

function directoryEntryFromAccountRow(row) {
  return {
    userId: row.user_id,
    username: row.username,
    identityAgreementKey: row.identity_agreement_key,
    identitySigningKey: row.identity_signing_key,
  };
}

/**
 * POST /prekeys/one-time  { userId, keys: [{ id, publicKey }] } -> 204
 * `req.userId` must equal `userId`: nobody may top up someone else's pool.
 * The pool is capped; keys beyond the cap are dropped (the pool is already full).
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
      let room = MAX_ONE_TIME_PREKEYS - store.stmt.countOneTimePreKeys.get(req.userId).n;
      for (const otk of body.keys) {
        if (room <= 0) break;
        if (store.stmt.insertOneTimePreKey.run(req.userId, otk.id, otk.publicKey).changes > 0) room -= 1;
      }
    });
    res.writeHead(204).end();
  };
}

/** POST /prekeys/signed  SignedPreKeyUpload -> 204 */
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
 * GET /directory/by-id/:userId, GET /directory/by-username/:username
 * The non-destructive lookup: never touches the one-time prekey pool.
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
 * GET /bundles/by-id/:userId, GET /bundles/by-username/:username
 *
 * Each call used to take one one-time prekey, so any logged-in user could drain
 * a victim's whole pool in a few calls, forcing every later handshake onto the
 * weaker no-dh4 path. Now one account takes at most 3 of another's per hour;
 * beyond that the bundle comes back WITHOUT a one-time prekey, which the client
 * already handles (X3DH simply skips dh4).
 */
function bundleByIdRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.prekeys, req, res)) return;
    if (!isValidUserId(req.params.userId)) return sendError(res, 400, 'badRequest', 'invalid userId');
    const account = store.stmt.accountById.get(req.params.userId);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');
    sendJson(res, 200, issueBundle(store, limiters, req.userId, account));
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
    sendJson(res, 200, issueBundle(store, limiters, req.userId, account));
  };
}

function issueBundle(store, limiters, requesterId, account) {
  const mayTakeOneTimeKey = limiters.bundlePair.take(`${requesterId}:${account.user_id}`);
  const popped = mayTakeOneTimeKey ? store.stmt.popOneTimePreKey.get(account.user_id, account.user_id) : null;
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
