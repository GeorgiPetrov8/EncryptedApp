'use strict';

const crypto = require('node:crypto');
const { nowIso } = require('./json');

/**
 * Proof of key possession: the server issues a single-use nonce, the client
 * signs it with the account's Ed25519 identity key. Used by login, account
 * deletion and recovery-email changes.
 *
 * FIX (S8, server half): domain separation. The same identity key also signs
 * signed prekeys, so signing a *raw* server-chosen value lets a malicious server
 * obtain a signature over 32 bytes it picked — e.g. a prekey of its own. Updated
 * clients sign `"SHC-challenge-v1" || nonce` instead, which can never be a valid
 * prekey message. Both forms are accepted while `LEGACY_CHALLENGE_SIGNATURES`
 * isn't `0`; turn it off once every client is updated.
 */
const CHALLENGE_TTL_MS = 60 * 1000;
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const CHALLENGE_CONTEXT = Buffer.from('SHC-challenge-v1', 'utf8');

const sha256 = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');

function ed25519Key(rawB64) {
  return crypto.createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, Buffer.from(rawB64, 'base64')]),
    format: 'der',
    type: 'spki',
  });
}

/** Verifies an Ed25519 signature over `message` with a base64 raw public key. */
function verifyEd25519(publicKeyB64, message, signatureB64) {
  try {
    const signature = Buffer.from(String(signatureB64), 'base64');
    if (signature.length !== 64) return false;
    return crypto.verify(null, message, ed25519Key(publicKeyB64), signature);
  } catch {
    return false;
  }
}

function issueChallenge(store, account) {
  store.stmt.deleteExpiredLoginChallenges.run(nowIso());
  const nonce = crypto.randomBytes(32).toString('base64');
  const createdAt = new Date();
  const expiresAt = new Date(createdAt.getTime() + CHALLENGE_TTL_MS);
  store.stmt.insertLoginChallenge.run(
    sha256(nonce), account.user_id, createdAt.toISOString(), expiresAt.toISOString(),
  );
  return { nonce, userId: account.user_id, expiresAt: expiresAt.toISOString(), context: 'SHC-challenge-v1' };
}

/**
 * FIX (S21): a challenge for a username that doesn't exist looks exactly like
 * a real one (stable fake user id, random nonce), so the unauthenticated login
 * endpoint no longer tells anyone which usernames are registered. Nothing is
 * stored; signing it can never succeed.
 */
function decoyChallenge(username, secret) {
  const digest = crypto.createHmac('sha256', secret).update(String(username).toLowerCase()).digest('hex');
  const userId = [digest.slice(0, 8), digest.slice(8, 12), `4${digest.slice(13, 16)}`,
    `${'89ab'[parseInt(digest[16], 16) % 4]}${digest.slice(17, 20)}`, digest.slice(20, 32)].join('-');
  return {
    nonce: crypto.randomBytes(32).toString('base64'),
    userId,
    expiresAt: new Date(Date.now() + CHALLENGE_TTL_MS).toISOString(),
    context: 'SHC-challenge-v1',
  };
}

/**
 * Verifies and consumes a signed challenge.
 * @returns {{ ok: true } | { ok: false, code: string, message: string }}
 */
function consumeChallenge(store, account, nonce, signatureB64) {
  if (typeof nonce !== 'string' || typeof signatureB64 !== 'string' || nonce.length > 100 || signatureB64.length > 200) {
    return { ok: false, code: 'badRequest', message: 'Missing nonce or signature.' };
  }
  if (!account) {
    return { ok: false, code: 'invalidChallenge', message: 'Invalid or expired challenge.' };
  }
  const nonceHash = sha256(nonce);
  const challenge = store.stmt.loginChallengeByHash.get(nonceHash);
  if (!challenge || challenge.user_id !== account.user_id) {
    return { ok: false, code: 'invalidChallenge', message: 'Invalid or expired challenge.' };
  }
  // Single-use: consumed on the first attempt, success or not.
  store.stmt.deleteLoginChallenge.run(nonceHash);
  if (new Date(challenge.expires_at).getTime() < Date.now()) {
    return { ok: false, code: 'invalidChallenge', message: 'The challenge has expired. Try again.' };
  }

  const nonceBytes = Buffer.from(nonce, 'base64');
  const separated = Buffer.concat([CHALLENGE_CONTEXT, nonceBytes]);
  let valid = verifyEd25519(account.identity_signing_key, separated, signatureB64);
  if (!valid && process.env.LEGACY_CHALLENGE_SIGNATURES !== '0') {
    valid = verifyEd25519(account.identity_signing_key, nonceBytes, signatureB64);
  }
  if (!valid) return { ok: false, code: 'invalidSignature', message: 'The signature did not verify.' };
  return { ok: true };
}

module.exports = { issueChallenge, decoyChallenge, consumeChallenge, verifyEd25519, CHALLENGE_CONTEXT };
