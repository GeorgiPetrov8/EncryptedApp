'use strict';

const crypto = require('node:crypto');
const { sendError, nowIso } = require('./json');

const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days
const TOKEN_BYTES = 32; // 256-bit opaque bearer token

/**
 * Opaque bearer tokens, not JWTs.
 *
 * A JWT would let the server validate a session without a database round
 * trip, but it can't be revoked short of a blocklist — which needs a
 * database anyway, defeating the point. An opaque token looked up against a
 * `sessions` table costs one indexed read per request and is trivially
 * revocable (delete the row), which matters here because logout, and any
 * future "sign out other devices" feature, must actually take effect
 * immediately rather than waiting out a token's expiry.
 *
 * Only the SHA-256 hash of the token is stored, matching how you'd store an
 * API key or a password: if the `sessions` table leaks, the tokens
 * themselves aren't directly reusable from the dump.
 */
function issueToken(store, userId) {
  const token = crypto.randomBytes(TOKEN_BYTES).toString('base64url');
  const tokenHash = hashToken(token);
  const now = new Date();
  const expiresAt = new Date(now.getTime() + SESSION_TTL_MS);
  store.stmt.insertSession.run(tokenHash, userId, now.toISOString(), expiresAt.toISOString());
  return token;
}

function hashToken(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest('hex');
}

/** Returns the userId for a valid, unexpired token, or null. */
function resolveToken(store, token) {
  if (typeof token !== 'string' || token.length === 0) return null;
  const row = store.stmt.sessionByHash.get(hashToken(token));
  if (!row) return null;
  if (new Date(row.expires_at).getTime() < Date.now()) return null;
  return row.user_id;
}

function extractBearerToken(req) {
  const header = req.headers['authorization'];
  if (!header || !header.startsWith('Bearer ')) return null;
  return header.slice('Bearer '.length).trim();
}

/**
 * Express-style middleware, adapted for the hand-rolled router in
 * `router.js`. On success sets `req.userId`; on failure writes the 401
 * response itself and returns `false` so the caller can bail out early.
 */
function requireAuth(store) {
  return function authMiddleware(req, res) {
    const token = extractBearerToken(req);
    const userId = resolveToken(store, token);
    if (!userId) {
      sendError(res, 401, 'notAuthenticated', 'Missing or invalid session token');
      return false;
    }
    req.userId = userId;
    return true;
  };
}

function pruneExpiredSessions(store) {
  store.stmt.deleteExpiredSessions.run(nowIso());
}

module.exports = { issueToken, resolveToken, extractBearerToken, requireAuth, pruneExpiredSessions };
