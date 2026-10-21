'use strict';

const { sendError } = require('./json');

const MAX_JSON_BODY_BYTES = 1024 * 1024; // 1 MiB

/** decodeURIComponent throws on input like "%E0%A4%A"; that must never escape. */
function safeDecode(segment) {
  try {
    return decodeURIComponent(segment);
  } catch {
    return null;
  }
}

/**
 * A small method+path router with `:param` segments, shaped like Express
 * (`router.get(path, handler)`, `req.params`, `req.query`).
 */
class Router {
  constructor() {
    this.routes = []; // { method, segments, handler }
  }

  _add(method, path, handler) {
    this.routes.push({ method, segments: path.split('/').filter(Boolean), handler });
  }

  get(path, handler) { this._add('GET', path, handler); }
  post(path, handler) { this._add('POST', path, handler); }

  /** @returns {{handler, params} | {malformed: true} | null} */
  match(method, pathname) {
    const segments = pathname.split('/').filter(Boolean);
    let malformed = false;

    for (const route of this.routes) {
      if (route.method !== method || route.segments.length !== segments.length) continue;

      const params = {};
      let matches = true;
      let undecodable = false;

      for (let i = 0; i < segments.length; i++) {
        const routeSegment = route.segments[i];
        if (routeSegment.startsWith(':')) {
          const value = safeDecode(segments[i]);
          if (value === null) { undecodable = true; break; }
          params[routeSegment.slice(1)] = value;
        } else if (routeSegment !== segments[i]) {
          matches = false;
          break;
        }
      }

      if (!matches) continue;
      if (undecodable) { malformed = true; continue; }
      return { handler: route.handler, params };
    }
    return malformed ? { malformed: true } : null;
  }
}

/**
 * Reads a request body.
 *  - `raw: true`  -> a Buffer
 *  - otherwise    -> a parsed JSON **object** (an empty body is `{}`).
 *
 * JSON that isn't an object (`null`, a number, an array) is rejected here, so
 * handlers can read `body.field` without first checking `body` itself — a
 * `null` body used to throw and surface as a 500.
 */
function readBody(req, { maxBytes = MAX_JSON_BODY_BYTES, raw = false } = {}) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let finished = false;

    const fail = (statusCode, message) => {
      if (finished) return;
      finished = true;
      reject(Object.assign(new Error(message), { statusCode }));
    };

    req.on('data', (chunk) => {
      if (finished) return;
      total += chunk.length;
      if (total > maxBytes) {
        chunks.length = 0;
        fail(413, 'payload too large');
        // Keep draining (discarding) so the 413 can still be delivered;
        // `dispatch` closes the connection once the response is out.
        return;
      }
      chunks.push(chunk);
    });

    req.on('end', () => {
      if (finished) return;
      finished = true;
      const buf = Buffer.concat(chunks);
      if (raw) return resolve(buf);
      if (buf.length === 0) return resolve({});
      let parsed;
      try {
        parsed = JSON.parse(buf.toString('utf8'));
      } catch {
        return reject(Object.assign(new Error('invalid JSON'), { statusCode: 400 }));
      }
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return reject(Object.assign(new Error('JSON body must be an object'), { statusCode: 400 }));
      }
      resolve(parsed);
    });

    req.on('error', () => fail(400, 'request error'));
    req.on('close', () => fail(400, 'connection closed'));
  });
}

/**
 * Routes one request. Everything — including path matching — runs inside the
 * `try`, so no request can throw past this function.
 */
async function dispatch(router, req, res, url) {
  try {
    const match = router.match(req.method, url.pathname);
    if (!match) return sendError(res, 404, 'notFound', 'No such route');
    if (match.malformed) return sendError(res, 400, 'badRequest', 'Malformed path');

    req.params = match.params;
    req.query = url.searchParams;
    await match.handler(req, res);
  } catch (err) {
    if (res.headersSent) {
      res.end();
      return;
    }
    if (err && err.statusCode) {
      const code = err.statusCode === 413 ? 'payloadTooLarge' : 'badRequest';
      if (err.statusCode === 413) {
        res.setHeader('Connection', 'close');
        res.once('finish', () => req.destroy());
      }
      sendError(res, err.statusCode, code, err.message);
    } else {
      console.error('Unhandled route error:', err);
      sendError(res, 500, 'internalError', 'Something went wrong');
    }
  }
}

module.exports = { Router, readBody, dispatch, safeDecode, MAX_JSON_BODY_BYTES };
