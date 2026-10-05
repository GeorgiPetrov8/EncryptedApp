'use strict';

const crypto = require('node:crypto');
const { nowIso } = require('./json');

/**
 * Proof of key possession: the server issues a single-use nonce, the client
 * signs it with the account's Ed25519 identity key. Used by login and by
 * account deletion — anything that must not work with a stolen bearer token
 * alone.
 */
const CHALLENGE_TTL_MS = 60 * 1000;
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

const sha256 = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');

function issueChallenge(store, account) {
  store.stmt.deleteExpiredLoginChallenges.run(nowIso());
  const nonce = crypto.randomBytes(32).toString('base64');
  const createdAt = new Date();
  const expiresAt = new Date(createdAt.getTime() + CHALLENGE_TTL_MS);
  store.stmt.insertLoginChallenge.run(
    sha256(nonce), account.user_id, createdAt.toISOString(), expiresAt.toISOString(),
  );
  // `userId` lets the client find the right keys on this device before
  // signing — without it, a device with several accounts can't know which
  // identity to sign with.
  return { nonce, userId: account.user_id, expiresAt: expiresAt.toISOString() };
}

/**
 * Verifies and consumes a signed challenge.
 * @returns {{ ok: true } | { ok: false, code: string, message: string }}
 */
function consumeChallenge(store, account, nonce, signatureB64) {
  if (typeof nonce !== 'string' || typeof signatureB64 !== 'string') {
    return { ok: false, code: 'badRequest', message: 'Missing nonce or signature.' };
  }
  const nonceHash = sha256(nonce);
  const challenge = store.stmt.loginChallengeByHash.get(nonceHash);
  if (!challenge || challenge.user_id !== account.user_id) {
    return { ok: false, code: 'invalidChallenge', message: 'Invalid or expired challenge.' };
  }
  // Single-use: consumed on the first attempt, success or not, so a
  // signature can't be brute-forced against one nonce.
  store.stmt.deleteLoginChallenge.run(nonceHash);
  if (new Date(challenge.expires_at).getTime() < Date.now()) {
    return { ok: false, code: 'invalidChallenge', message: 'The challenge has expired. Try again.' };
  }

  const signature = Buffer.from(signatureB64, 'base64');
  if (signature.length !== 64) {
    return { ok: false, code: 'invalidSignature', message: 'Invalid signature.' };
  }
  let valid = false;
  try {
    const key = crypto.createPublicKey({
      key: Buffer.concat([ED25519_SPKI_PREFIX, Buffer.from(account.identity_signing_key, 'base64')]),
      format: 'der',
      type: 'spki',
    });
    valid = crypto.verify(null, Buffer.from(nonce, 'base64'), key, signature);
  } catch {
    valid = false;
  }
  if (!valid) return { ok: false, code: 'invalidSignature', message: 'The signature did not verify.' };
  return { ok: true };
}

module.exports = { issueChallenge, consumeChallenge };
