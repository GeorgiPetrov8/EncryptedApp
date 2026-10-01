'use strict';

const { sendError } = require('./json');

const MAX_JSON_BODY_BYTES = 1024 * 1024; // 1 MiB — generous for any JSON payload here

/**
 * A small method+path router with `:param` segments. Not Express — there is
 * no Express in this offline environment — but shaped closely enough after
 * it (`router.get(path, handler)`, `req.params`, `req.query`) that porting
 * to Express later, if the project ever needs middleware this doesn't have,
 * is a mechanical find-and-replace rather than a rewrite.
 */
class Router {
  constructor() {
    this.routes = []; // { method, segments, handler }
  }

  _add(method, path, handler) {
    const segments = path.split('/').filter(Boolean);
    this.routes.push({ method, segments, handler });
  }

  get(path, handler) { this._add('GET', path, handler); }
  post(path, handler) { this._add('POST', path, handler); }

  match(method, pathname) {
    const segments = pathname.split('/').filter(Boolean);
    for (const route of this.routes) {
      if (route.method !== method) continue;
      if (route.segments.length !== segments.length) continue;
      const params = {};
      let ok = true;
      for (let i = 0; i < segments.length; i++) {
        const rs = route.segments[i];
        if (rs.startsWith(':')) {
          params[rs.slice(1)] = decodeURIComponent(segments[i]);
        } else if (rs !== segments[i]) {
          ok = false;
          break;
        }
      }
      if (ok) return { handler: route.handler, params };
    }
    return null;
  }
}

function readBody(req, { maxBytes = MAX_JSON_BODY_BYTES, raw = false } = {}) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject(Object.assign(new Error('payload too large'), { statusCode: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      const buf = Buffer.concat(chunks);
      if (raw) return resolve(buf);
      if (buf.length === 0) return resolve({});
      try {
        resolve(JSON.parse(buf.toString('utf8')));
      } catch {
        reject(Object.assign(new Error('invalid JSON'), { statusCode: 400 }));
      }
    });
    req.on('error', reject);
  });
}

async function dispatch(router, req, res, url) {
  const match = router.match(req.method, url.pathname);
  if (!match) {
    sendError(res, 404, 'notFound', 'No such route');
    return;
  }
  req.params = match.params;
  req.query = url.searchParams;
  try {
    await match.handler(req, res);
  } catch (err) {
    if (err && err.statusCode) {
      sendError(res, err.statusCode, 'badRequest', err.message);
    } else {
      // eslint-disable-next-line no-console
      console.error('Unhandled route error:', err);
      sendError(res, 500, 'internalError', 'Something went wrong');
    }
  }
}

module.exports = { Router, readBody, dispatch, MAX_JSON_BODY_BYTES };
