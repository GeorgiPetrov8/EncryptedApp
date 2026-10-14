'use strict';

const crypto = require('node:crypto');
const { sendError, nowIso } = require('./json');

const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days
const TOKEN_BYTES = 32; // 256-bit opaque bearer token

/**
 * Opaque bearer tokens, not JWTs: one indexed read per request, and trivially
 * revocable (delete the row), which logout and account recovery rely on. Only
 * the SHA-256 hash is stored, so a leaked `sessions` table holds no usable
 * tokens.
 */
function issueToken(store, userId) {
  const token = crypto.randomBytes(TOKEN_BYTES).toString('base64url');
  const now = new Date();
  const expiresAt = new Date(now.getTime() + SESSION_TTL_MS);
  store.stmt.insertSession.run(hashToken(token), userId, now.toISOString(), expiresAt.toISOString());
  return token;
}

function hashToken(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest('hex');
}

/** Returns the userId for a valid, unexpired token, or null. */
function resolveToken(store, token) {
  if (typeof token !== 'string' || token.length === 0 || token.length > 256) return null;
  const row = store.stmt.sessionByHash.get(hashToken(token));
  if (!row) return null;
  if (new Date(row.expires_at).getTime() < Date.now()) return null;
  return row.user_id;
}

/** Deletes one session. Returns true if it existed. */
function revokeToken(store, token) {
  if (typeof token !== 'string' || !token) return false;
  return store.stmt.deleteSessionByHash.run(hashToken(token)).changes > 0;
}

function extractBearerToken(req) {
  const header = req.headers['authorization'];
  if (!header || !header.startsWith('Bearer ')) return null;
  return header.slice('Bearer '.length).trim();
}

/**
 * Middleware for the hand-rolled router: on success sets `req.userId`; on
 * failure writes the 401 itself and returns `false`.
 */
function requireAuth(store) {
  return function authMiddleware(req, res) {
    const userId = resolveToken(store, extractBearerToken(req));
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

module.exports = {
  issueToken, resolveToken, revokeToken, hashToken, extractBearerToken, requireAuth, pruneExpiredSessions,
};
