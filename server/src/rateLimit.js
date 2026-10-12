'use strict';

const { sendError } = require('./json');

/**
 * Fixed-window rate limiter, keyed by client IP + route bucket.
 *
 * In-memory, per-process. That is the right amount of complexity for a
 * single-instance deployment; the moment you run more than one server
 * process behind a load balancer, this needs to move to Redis (`INCR` +
 * `EXPIRE`, or a sliding-window Lua script) so limits are shared across
 * instances instead of each instance granting its own separate quota. The
 * function signature below (`take(key) -> boolean`) is deliberately the
 * same shape a Redis-backed version would have, so that swap doesn't touch
 * any route handler.
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

  /** Periodic sweep so the Map doesn't grow unboundedly under high IP churn. */
  sweep() {
    const now = Date.now();
    for (const [key, entry] of this.hits) {
      if (now - entry.windowStart >= this.windowMs) this.hits.delete(key);
    }
  }
}

function clientIp(req) {
  // Trust X-Forwarded-For only when running behind the bundled Caddy reverse
  // proxy (see Caddyfile), which sets it and discards any client-supplied
  // copy. Do not enable this if the server is ever exposed directly.
  const forwarded = req.headers['x-forwarded-for'];
  if (process.env.TRUST_PROXY === '1' && forwarded) {
    return forwarded.split(',')[0].trim();
  }
  return req.socket.remoteAddress || 'unknown';
}

/**
 * Deliberately stricter for auth/registration endpoints than for message
 * sending — the former is where credential-stuffing and account-creation
 * abuse show up, the latter is where a legitimate chatty client lives.
 */
function makeLimiters() {
  return {
    auth: new RateLimiter({ windowMs: 60_000, max: 10 }), // register/login
    prekeys: new RateLimiter({ windowMs: 60_000, max: 30 }),
    messages: new RateLimiter({ windowMs: 60_000, max: 120 }),
    media: new RateLimiter({ windowMs: 60_000, max: 30 }),
    directory: new RateLimiter({ windowMs: 60_000, max: 60 }),
  };
}

function rateLimit(limiter, req, res) {
  const key = clientIp(req);
  if (!limiter.take(key)) {
    sendError(res, 429, 'rateLimited', 'Too many requests. Try again shortly.');
    return false;
  }
  return true;
}

module.exports = { makeLimiters, rateLimit, clientIp, RateLimiter };
