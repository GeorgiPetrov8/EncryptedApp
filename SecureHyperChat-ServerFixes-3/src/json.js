'use strict';

/**
 * Wire-format helpers shared by every route.
 *
 * The client's Swift JSONEncoder/Decoder (`SecureHyperChatJSON`) uses exact
 * camelCase keys, base64 strings for `Data` and ISO-8601 strings for `Date`.
 */

function nowIso() {
  return new Date().toISOString();
}

/**
 * Strict, canonical base64: standard alphabet, correct padding, and the value
 * must re-encode to exactly the same string (Swift's `Data(base64Encoded:)`
 * rejects anything else).
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

/**
 * FIX (R13): every response says "don't store me". Responses carry ciphertext,
 * metadata and account data; a client-side or intermediary cache (including a
 * misconfigured CDN rule) must never keep them.
 */
const SECURITY_HEADERS = {
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
};

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    ...SECURITY_HEADERS,
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
  });
  res.end(payload);
}

/** `{ error: "<code>", message }` — the code maps to the client's error cases. */
function sendError(res, status, errorCode, message, extra = {}) {
  sendJson(res, status, { error: errorCode, message: message || errorCode, ...extra });
}

/** 204 with the same headers. */
function sendNoContent(res) {
  res.writeHead(204, SECURITY_HEADERS).end();
}

module.exports = { nowIso, isValidBase64, sendJson, sendError, sendNoContent, SECURITY_HEADERS };
