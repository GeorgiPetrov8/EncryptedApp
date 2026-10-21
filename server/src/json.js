'use strict';

/**
 * Wire-format helpers shared by every route.
 *
 * The client's Swift JSONEncoder/Decoder (see `HyperChatJSON` /
 * `SecureHyperChatJSON`) uses exact camelCase keys, base64 strings for `Data`
 * and ISO-8601 strings for `Date`.
 */

function nowIso() {
  return new Date().toISOString();
}

/**
 * Strict, canonical base64: standard alphabet, correct padding, and the value
 * must re-encode to exactly the same string.
 *
 * The previous check accepted unpadded or oddly-padded input that Node decodes
 * happily but Swift's `Data(base64Encoded:)` rejects — so a bad value passed
 * the server and then broke every client that fetched it.
 */
function isValidBase64(value, { exactByteLength } = {}) {
  if (typeof value !== 'string' || value.length === 0) return false;
  if (value.length % 4 !== 0) return false;
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return false;
  let buf;
  try {
    buf = Buffer.from(value, 'base64');
  } catch {
    return false;
  }
  if (buf.length === 0) return false;
  if (buf.toString('base64') !== value) return false;
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

/** `{ error: "<code>", message }` — the code maps to the client's error cases. */
function sendError(res, status, errorCode, message) {
  sendJson(res, status, { error: errorCode, message: message || errorCode });
}

module.exports = { nowIso, isValidBase64, sendJson, sendError };
