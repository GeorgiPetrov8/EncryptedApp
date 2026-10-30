'use strict';

const { sendError } = require('./json');

/**
 * Fixed-window rate limiter keyed by a string (client IP, account id, ...).
 * In-memory and per-process: right for one instance.
 */
class RateLimiter {
  constructor({ windowMs, max }) {
    this.windowMs = windowMs;
    this.max = max;
    this.hits = new Map(); // key -> { count, windowStart }
  }

  take(key) {
    const now = Date.now();
    const entry = this.hits.get(key);
    if (!entry || now - entry.windowStart >= this.windowMs) {
      this.hits.set(key, { count: 1, windowStart: now });
      return true;
    }
    if (entry.count >= this.max) return false;
    entry.count += 1;
    return true;
  }

  sweep() {
    const now = Date.now();
    for (const [key, entry] of this.hits) {
      if (now - entry.windowStart >= this.windowMs) this.hits.delete(key);
    }
  }
}

/** "1.2.3.4:5555" and "[::1]:443" -> the bare address. */
function stripPort(value) {
  const v = String(value).trim();
  const bracketed = v.match(/^\[([^\]]+)\](?::\d+)?$/);
  if (bracketed) return bracketed[1];
  if (/^\d{1,3}(\.\d{1,3}){3}:\d+$/.test(v)) return v.slice(0, v.lastIndexOf(':'));
  return v;
}

/**
 * The client's IP address.
 *
 * FIX (S6): behind Cloudflare the last `X-Forwarded-For` entry is a Cloudflare
 * edge, so every user shared one bucket and ten logins a minute locked out the
 * whole server. Modes (`TRUST_PROXY`):
 *
 *   unset / "0"   socket address (server reachable directly)
 *   "1"           exactly one trusted proxy in front (e.g. Caddy): the LAST
 *                 `X-Forwarded-For` entry, which that proxy appended
 *   "cloudflare"  `CF-Connecting-IP`. ONLY safe when the server can be reached
 *                 exclusively through Cloudflare (Cloudflare Tunnel, or a firewall
 *                 allowing only Cloudflare's ranges); otherwise anyone can send
 *                 the header and pick their own bucket.
 */
function clientIp(req) {
  const mode = process.env.TRUST_PROXY;
  if (mode === 'cloudflare') {
    const cf = req.headers['cf-connecting-ip'];
    if (typeof cf === 'string' && cf.length <= 64) return stripPort(cf);
  } else if (mode === '1') {
    const forwarded = req.headers['x-forwarded-for'];
    if (forwarded) {
      const parts = String(forwarded).split(',');
      return stripPort(parts[parts.length - 1]);
    }
  }
  return req.socket?.remoteAddress || 'unknown';
}

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;

/**
 * FIX (S6): the single `auth` bucket (10/min) was shared by register, login,
 * recovery, email and account deletion — people behind one NAT, or one
 * Cloudflare edge, locked each other out. Each flow now has its own bucket.
 */
function makeLimiters() {
  return {
    // Signed-out flows, per IP.
    register: new RateLimiter({ windowMs: HOUR, max: 5 }),
    login: new RateLimiter({ windowMs: MINUTE, max: 20 }),
    recovery: new RateLimiter({ windowMs: MINUTE, max: 10 }),
    // Signed-in account actions, per account.
    auth: new RateLimiter({ windowMs: MINUTE, max: 20 }),
    prekeys: new RateLimiter({ windowMs: MINUTE, max: 30 }),
    messages: new RateLimiter({ windowMs: MINUTE, max: 120 }),
    media: new RateLimiter({ windowMs: MINUTE, max: 30 }),
    directory: new RateLimiter({ windowMs: MINUTE, max: 60 }),
    // Recovery email / codes.
    emailPerAddress: new RateLimiter({ windowMs: HOUR, max: 3 }),
    codesPerAccount: new RateLimiter({ windowMs: HOUR, max: 10 }),
    codesPerAccountAndIp: new RateLimiter({ windowMs: HOUR, max: 3 }),
    codeChecks: new RateLimiter({ windowMs: HOUR, max: 50 }),
    codeChecksPerIp: new RateLimiter({ windowMs: HOUR, max: 10 }),
    // One account taking another's one-time prekeys.
    bundlePair: new RateLimiter({ windowMs: HOUR, max: 3 }),
    // Unauthenticated WebSocket sockets per IP (see server.js).
    wsUpgrades: new RateLimiter({ windowMs: MINUTE, max: 30 }),
  };
}

/**
 * FIX (S6): signed-in requests are limited per **account**, signed-out ones per
 * IP. A family or office behind one address no longer shares a quota, and an
 * attacker can't spend someone else's.
 */
function rateLimit(limiter, req, res) {
  const key = req.userId ? `u:${req.userId}` : `ip:${clientIp(req)}`;
  if (!limiter.take(key)) {
    sendError(res, 429, 'rateLimited', 'Too many requests. Try again shortly.');
    return false;
  }
  return true;
}

module.exports = { makeLimiters, rateLimit, clientIp, stripPort, RateLimiter };
