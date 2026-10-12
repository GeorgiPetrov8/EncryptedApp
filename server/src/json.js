'use strict';

/**
 * Wire-format helpers shared by every route.
 *
 * The client's Swift `JSONEncoder`/`JSONDecoder` (as configured in
 * `RealAPIClient`) uses:
 *   - exact camelCase keys (no snake_case conversion),
 *   - `Data` fields encoded as base64 strings (Swift's default),
 *   - `Date` fields encoded as ISO-8601 strings (explicitly configured on
 *     the client to avoid Swift's default `.deferredToDate`, which emits a
 *     bare floating-point timestamp and would otherwise have to be matched
 *     byte-for-byte here).
 *
 * Every response body in this server is built to match those three rules
 * exactly. If you add a field, encode it the same way or the client's
 * `Codable` conformance will fail to decode the response.
 */

function nowIso() {
  return new Date().toISOString();
}

function isValidBase64(value, { exactByteLength } = {}) {
  if (typeof value !== 'string' || value.length === 0) return false;
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return false;
  let buf;
  try {
    buf = Buffer.from(value, 'base64');
  } catch {
    return false;
  }
  // Buffer.from is lenient about padding; re-encode and compare length class
  // to reject garbage that merely contains valid base64 characters.
  if (buf.length === 0) return false;
  if (typeof exactByteLength === 'number' && buf.length !== exactByteLength) return false;
  return true;
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
  });
  res.end(payload);
}

/**
 * Maps to the client's `APIError` cases by string identifier so
 * `RealAPIClient` can decode `{ "error": "usernameTaken" }` the same way it
 * already handles `APIError` from the mock.
 */
function sendError(res, status, errorCode, message) {
  sendJson(res, status, { error: errorCode, message: message || errorCode });
}

module.exports = { nowIso, isValidBase64, sendJson, sendError };
