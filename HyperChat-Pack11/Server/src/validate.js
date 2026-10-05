'use strict';

const { isValidBase64 } = require('./json');

/**
 * Server-side shape validation. The server never uses these bytes
 * cryptographically, but it can cheaply reject malformed or oversized
 * "keys" before they're stored.
 */
const X25519_KEY_BYTES = 32;
const ED25519_KEY_BYTES = 32;
const ED25519_SIGNATURE_BYTES = 64;

const USERNAME_RE = /^[a-zA-Z0-9_.-]{3,32}$/;
const USER_ID_RE = /^[a-zA-Z0-9-]{1,64}$/;

/**
 * Every envelope content type the app sends.
 *
 * FIX: 'call' and 'edit' were missing, so the server answered every call
 * signal and every message edit with 400 — calls could never connect and
 * edits never reached the other side. Keep this list in sync with
 * `EnvelopePayloadKind` in DTOs.swift; `test/server.test.js` checks it.
 */
const ALLOWED_CONTENT_TYPES = [
  'text', 'image', 'video', 'file',
  'notePad', 'receipt', 'profile', 'invite', 'call', 'edit',
];

function isValidUsername(value) {
  return typeof value === 'string' && USERNAME_RE.test(value);
}

function isValidUserId(value) {
  return typeof value === 'string' && USER_ID_RE.test(value);
}

function isValidUInt32(value) {
  return Number.isInteger(value) && value >= 0 && value <= 0xffffffff;
}

function validateBundleUpload(body) {
  if (!body || typeof body !== 'object') return 'malformed body';
  if (!isValidUserId(body.userId)) return 'invalid userId';
  if (!isValidUsername(body.username)) return 'invalid username';
  if (!isValidBase64(body.identityAgreementKey, { exactByteLength: X25519_KEY_BYTES })) {
    return 'invalid identityAgreementKey';
  }
  if (!isValidBase64(body.identitySigningKey, { exactByteLength: ED25519_KEY_BYTES })) {
    return 'invalid identitySigningKey';
  }
  if (!isValidUInt32(body.signedPreKeyId)) return 'invalid signedPreKeyId';
  if (!isValidBase64(body.signedPreKey, { exactByteLength: X25519_KEY_BYTES })) {
    return 'invalid signedPreKey';
  }
  if (!isValidBase64(body.signedPreKeySignature, { exactByteLength: ED25519_SIGNATURE_BYTES })) {
    return 'invalid signedPreKeySignature';
  }
  if (!Array.isArray(body.oneTimePreKeys) || body.oneTimePreKeys.length > 200) {
    return 'invalid oneTimePreKeys';
  }
  for (const otk of body.oneTimePreKeys) {
    if (!otk || !isValidUInt32(otk.id)) return 'invalid one-time prekey id';
    if (!isValidBase64(otk.publicKey, { exactByteLength: X25519_KEY_BYTES })) {
      return 'invalid one-time prekey publicKey';
    }
  }
  return null;
}

function validateSignedPreKeyUpload(body) {
  if (!body || typeof body !== 'object') return 'malformed body';
  if (!isValidUserId(body.userId)) return 'invalid userId';
  if (!isValidUInt32(body.signedPreKeyId)) return 'invalid signedPreKeyId';
  if (!isValidBase64(body.signedPreKey, { exactByteLength: X25519_KEY_BYTES })) {
    return 'invalid signedPreKey';
  }
  if (!isValidBase64(body.signedPreKeySignature, { exactByteLength: ED25519_SIGNATURE_BYTES })) {
    return 'invalid signedPreKeySignature';
  }
  return null;
}

function validateOneTimePreKeyBatch(body) {
  if (!body || !Array.isArray(body.keys) || body.keys.length === 0 || body.keys.length > 200) {
    return 'invalid keys';
  }
  for (const otk of body.keys) {
    if (!otk || !isValidUInt32(otk.id)) return 'invalid one-time prekey id';
    if (!isValidBase64(otk.publicKey, { exactByteLength: X25519_KEY_BYTES })) {
      return 'invalid one-time prekey publicKey';
    }
  }
  return null;
}

const MAX_RATCHET_MESSAGE_BYTES = 256 * 1024;
const MAX_ENVELOPE_ID_LENGTH = 128;

function validateEnvelope(body) {
  if (!body || typeof body !== 'object') return 'malformed body';
  if (typeof body.id !== 'string' || body.id.length === 0 || body.id.length > MAX_ENVELOPE_ID_LENGTH) {
    return 'invalid id';
  }
  if (typeof body.conversationId !== 'string' || body.conversationId.length === 0 || body.conversationId.length > 128) {
    return 'invalid conversationId';
  }
  if (!isValidUserId(body.senderId)) return 'invalid senderId';
  if (!isValidUserId(body.recipientId)) return 'invalid recipientId';
  if (body.kind !== 'handshake' && body.kind !== 'ratchet') return 'invalid kind';
  if (!isValidBase64(body.ratchetMessage) || Buffer.from(body.ratchetMessage, 'base64').length > MAX_RATCHET_MESSAGE_BYTES) {
    return 'invalid or oversized ratchetMessage';
  }
  if (!ALLOWED_CONTENT_TYPES.includes(body.contentType)) return 'invalid contentType';
  if (body.kind === 'handshake') {
    const h = body.handshake;
    if (!h || typeof h !== 'object') return 'missing handshake payload';
    if (!isValidBase64(h.identityAgreementKey, { exactByteLength: X25519_KEY_BYTES })) return 'invalid handshake.identityAgreementKey';
    if (!isValidBase64(h.identitySigningKey, { exactByteLength: ED25519_KEY_BYTES })) return 'invalid handshake.identitySigningKey';
    if (!isValidBase64(h.ephemeralPublicKey, { exactByteLength: X25519_KEY_BYTES })) return 'invalid handshake.ephemeralPublicKey';
    if (!isValidUInt32(h.usedSignedPreKeyId)) return 'invalid handshake.usedSignedPreKeyId';
    if (h.usedOneTimePreKeyId !== null && h.usedOneTimePreKeyId !== undefined && !isValidUInt32(h.usedOneTimePreKeyId)) {
      return 'invalid handshake.usedOneTimePreKeyId';
    }
    if (h.senderUsername !== null && h.senderUsername !== undefined && !isValidUsername(h.senderUsername)) {
      return 'invalid handshake.senderUsername';
    }
  }
  return null;
}

const MAX_MEDIA_BYTES = 25 * 1024 * 1024;

module.exports = {
  X25519_KEY_BYTES,
  ED25519_KEY_BYTES,
  ED25519_SIGNATURE_BYTES,
  MAX_MEDIA_BYTES,
  ALLOWED_CONTENT_TYPES,
  isValidUsername,
  isValidUserId,
  isValidUInt32,
  validateBundleUpload,
  validateSignedPreKeyUpload,
  validateOneTimePreKeyBatch,
  validateEnvelope,
};
