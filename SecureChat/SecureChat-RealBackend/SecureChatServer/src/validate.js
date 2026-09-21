'use strict';

const { isValidBase64 } = require('./json');

/**
 * Server-side shape validation for key material.
 *
 * The server is zero-knowledge — it never uses these bytes cryptographically
 * and cannot tell a valid Curve25519 point from random noise. But it *can*
 * cheaply check that a field claiming to be an X25519/Ed25519 key is exactly
 * 32 bytes, and that a signature is exactly 64 bytes, before ever writing it
 * to disk. That closes off a cheap storage-bloat / malformed-data denial of
 * service: without this, a client (or attacker with a stolen session token)
 * could POST arbitrarily large "keys" and have the server persist them
 * forever in `accounts`/`one_time_prekeys`.
 */
const X25519_KEY_BYTES = 32;
const ED25519_KEY_BYTES = 32;
const ED25519_SIGNATURE_BYTES = 64;

const USERNAME_RE = /^[a-zA-Z0-9_.-]{3,32}$/;
const USER_ID_RE = /^[a-zA-Z0-9-]{1,64}$/; // Swift UUID().uuidString shape, kept loose

function isValidUsername(value) {
  return typeof value === 'string' && USERNAME_RE.test(value);
}

function isValidUserId(value) {
  return typeof value === 'string' && USER_ID_RE.test(value);
}

function isValidUInt32(value) {
  return Number.isInteger(value) && value >= 0 && value <= 0xffffffff;
}

/** Validates the shape of a `PreKeyBundleUpload`. Returns an error string, or null if valid. */
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

// Generous but bounded: text messages are small; images/videos go through
// /media as their own upload, so the ratchet payload here is just a JSON key
// pointer for those, never the file itself. 256 KiB comfortably covers a
// worst-case oversized handshake payload with room to spare.
const MAX_RATCHET_MESSAGE_BYTES = 256 * 1024;
const MAX_ENVELOPE_ID_LENGTH = 128;

function validateEnvelope(body) {
  if (!body || typeof body !== 'object') return 'malformed body';
  if (typeof body.id !== 'string' || body.id.length === 0 || body.id.length > MAX_ENVELOPE_ID_LENGTH) {
    return 'invalid id';
  }
  if (!isValidUserId(body.conversationId) && !/^[a-f0-9]{64}$/.test(body.conversationId || '')) {
    // Accepts both legacy UUID-shaped ids and the SHA-256 hex deterministic
    // ids the client computes for 1:1 conversations.
    if (typeof body.conversationId !== 'string' || body.conversationId.length === 0) {
      return 'invalid conversationId';
    }
  }
  if (!isValidUserId(body.senderId)) return 'invalid senderId';
  if (!isValidUserId(body.recipientId)) return 'invalid recipientId';
  if (body.kind !== 'handshake' && body.kind !== 'ratchet') return 'invalid kind';
  if (!isValidBase64(body.ratchetMessage) || Buffer.from(body.ratchetMessage, 'base64').length > MAX_RATCHET_MESSAGE_BYTES) {
    return 'invalid or oversized ratchetMessage';
  }
  // FIX (shared notepad): 'notePad' added to the allow-list.
  //
  // The server never interprets ciphertext — this array exists purely as a
  // cheap shape check, the same reason 'image'/'video'/'file' are here. A
  // notepad sync envelope is exactly as opaque to this server as a text
  // message; it differs only in what the *client* does with the decrypted
  // bytes (merge into a shared checklist instead of rendering a chat
  // bubble — see MessagingService.handleIncoming's early-return branch for
  // `.notePad` on the client).
  if (!['text', 'image', 'video', 'file', 'notePad'].includes(body.contentType)) return 'invalid contentType';
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

// Media: uploaded as raw bytes with a declared content-length cap. 25 MiB
// matches a generous phone-camera photo; video should be chunked/streamed in
// a production build (see README) rather than raised past this ceiling.
const MAX_MEDIA_BYTES = 25 * 1024 * 1024;

module.exports = {
  X25519_KEY_BYTES,
  ED25519_KEY_BYTES,
  ED25519_SIGNATURE_BYTES,
  MAX_MEDIA_BYTES,
  isValidUsername,
  isValidUserId,
  isValidUInt32,
  validateBundleUpload,
  validateSignedPreKeyUpload,
  validateOneTimePreKeyBatch,
  validateEnvelope,
};
