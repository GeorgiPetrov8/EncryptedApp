'use strict';

const { sendError } = require('./json');

/**
 * Fixed-window rate limiter keyed by a string (client IP, account id, ...).
 *
 * In-memory and per-process: right for one instance. Behind several instances
 * it needs Redis, with the same `take(key) -> boolean` shape.
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

  /** Drops expired windows so the map can't grow without bound. */
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

function clientIp(req) {
  // Behind exactly one trusted proxy (the bundled Caddy), the proxy's own entry
  // is the LAST one in X-Forwarded-For; anything a client sent sits to its
  // left. Reading the first entry — as this used to — trusts the attacker.
  // Never enable TRUST_PROXY if the server is reachable directly.
  const forwarded = req.headers['x-forwarded-for'];
  if (process.env.TRUST_PROXY === '1' && forwarded) {
    const parts = String(forwarded).split(',');
    return stripPort(parts[parts.length - 1]);
  }
  return req.socket.remoteAddress || 'unknown';
}

const HOUR = 60 * 60 * 1000;

function makeLimiters() {
  return {
    auth: new RateLimiter({ windowMs: 60_000, max: 10 }),
    prekeys: new RateLimiter({ windowMs: 60_000, max: 30 }),
    messages: new RateLimiter({ windowMs: 60_000, max: 120 }),
    media: new RateLimiter({ windowMs: 60_000, max: 30 }),
    directory: new RateLimiter({ windowMs: 60_000, max: 60 }),
    // Recovery email / codes (keyed by account or address, not IP):
    emailPerAddress: new RateLimiter({ windowMs: HOUR, max: 3 }),
    codesPerAccount: new RateLimiter({ windowMs: HOUR, max: 5 }),
    codeChecks: new RateLimiter({ windowMs: HOUR, max: 30 }),
    // How often one account may take a one-time prekey of one other account.
    bundlePair: new RateLimiter({ windowMs: HOUR, max: 3 }),
  };
}

function rateLimit(limiter, req, res) {
  if (!limiter.take(clientIp(req))) {
    sendError(res, 429, 'rateLimited', 'Too many requests. Try again shortly.');
    return false;
  }
  return true;
}

module.exports = { makeLimiters, rateLimit, clientIp, stripPort, RateLimiter };
