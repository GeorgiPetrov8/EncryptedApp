'use strict';

const { sendJson, sendError, sendNoContent } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const {
  validateSignedPreKeyUpload, validateOneTimePreKeyBatch, isValidUsername, isValidUserId,
} = require('../validate');

const MAX_ONE_TIME_PREKEYS = 200;

function directoryEntryFromAccountRow(row) {
  return {
    userId: row.user_id,
    username: row.username,
    identityAgreementKey: row.identity_agreement_key,
    identitySigningKey: row.identity_signing_key,
  };
}

function replenishOneTimePreKeysRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.prekeys, req, res)) return;
    const body = await readBody(req);
    if (body.userId !== req.userId) return sendError(res, 403, 'forbidden', 'Cannot modify another account\'s prekeys');
    const validationError = validateOneTimePreKeyBatch(body);
    if (validationError) return sendError(res, 400, 'badRequest', validationError);

    store.transaction(() => {
      let room = MAX_ONE_TIME_PREKEYS - store.stmt.countOneTimePreKeys.get(req.userId).n;
      for (const otk of body.keys) {
        if (room <= 0) break;
        if (store.stmt.insertOneTimePreKey.run(req.userId, otk.id, otk.publicKey).changes > 0) room -= 1;
      }
    });
    sendNoContent(res);
  };
}

/** POST /prekeys/signed — FIX (S14): the signature is checked with the stored identity key. */
function publishSignedPreKeyRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.prekeys, req, res)) return;
    const body = await readBody(req);
    if (body.userId !== req.userId) return sendError(res, 403, 'forbidden', 'Cannot modify another account\'s prekeys');
    const account = store.stmt.accountById.get(req.userId);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');
    const validationError = validateSignedPreKeyUpload(body, account.identity_signing_key);
    if (validationError) return sendError(res, 400, 'badRequest', validationError);

    store.stmt.updateSignedPreKey.run(body.signedPreKeyId, body.signedPreKey, body.signedPreKeySignature, req.userId);
    sendNoContent(res);
  };
}

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
  const mayTake = requesterId !== account.user_id && limiters.bundlePair.take(`${requesterId}:${account.user_id}`);
  const popped = mayTake ? store.stmt.popOneTimePreKey.get(account.user_id, account.user_id) : null;
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
