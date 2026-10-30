'use strict';

const crypto = require('node:crypto');
const { sendError, nowIso } = require('./json');

const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days
const TOKEN_BYTES = 32;
/** last_used_at is written at most this often per session. */
const TOUCH_INTERVAL_MS = 60 * 60 * 1000;

function hashToken(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest('hex');
}

function issueToken(store, userId) {
  const token = crypto.randomBytes(TOKEN_BYTES).toString('base64url');
  const now = new Date();
  const expiresAt = new Date(now.getTime() + SESSION_TTL_MS);
  store.stmt.insertSession.run(hashToken(token), userId, now.toISOString(), expiresAt.toISOString(), now.toISOString());
  return token;
}

/**
 * Returns the userId for a valid, unexpired token, or null. Records (at most
 * hourly) that the session is in use — needed to tell whether a device is still
 * signed in when someone tries to recover the account (S2).
 */
function resolveToken(store, token) {
  if (typeof token !== 'string' || token.length === 0 || token.length > 256) return null;
  const hash = hashToken(token);
  const row = store.stmt.sessionByHash.get(hash);
  if (!row) return null;
  const now = Date.now();
  if (new Date(row.expires_at).getTime() < now) return null;
  const lastUsed = row.last_used_at ? new Date(row.last_used_at).getTime() : 0;
  if (now - lastUsed > TOUCH_INTERVAL_MS) {
    try { store.stmt.touchSession.run(new Date(now).toISOString(), hash); } catch { /* best effort */ }
  }
  return row.user_id;
}

function revokeToken(store, token) {
  if (typeof token !== 'string' || !token) return false;
  return store.stmt.deleteSessionByHash.run(hashToken(token)).changes > 0;
}

function extractBearerToken(req) {
  const header = req.headers['authorization'];
  if (!header || !header.startsWith('Bearer ')) return null;
  return header.slice('Bearer '.length).trim();
}

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
  SESSION_TTL_MS,
};
