'use strict';

const { isValidBase64 } = require('./json');

/**
 * Server-side shape validation. The server never uses these bytes
 * cryptographically, but it can cheaply reject malformed or oversized values
 * before they're stored or relayed.
 */
const X25519_KEY_BYTES = 32;
const ED25519_KEY_BYTES = 32;
const ED25519_SIGNATURE_BYTES = 64;

const USERNAME_RE = /^[a-zA-Z0-9_.-]{3,32}$/;
const USER_ID_RE = /^[a-zA-Z0-9-]{1,64}$/;
// The app creates user ids with UUID().uuidString. Requiring that on
// registration stops a client reserving ids like "a", or ids that collide.
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const OPAQUE_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;

/**
 * Every envelope content type the app sends. Keep in sync with
 * `EnvelopePayloadKind` in DTOs.swift — a type missing here is rejected with
 * 400 and the feature silently stops working.
 */
const ALLOWED_CONTENT_TYPES = [
  'text', 'image', 'video', 'file',
  'notePad', 'receipt', 'profile', 'invite', 'call', 'edit', 'reaction',
];

const MAX_RATCHET_MESSAGE_BYTES = 256 * 1024;
const MAX_MEDIA_BYTES = 25 * 1024 * 1024;
/** A message may carry a createdAt this far ahead of the server clock. */
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;

const isValidUsername = (v) => typeof v === 'string' && USERNAME_RE.test(v);
const isValidUserId = (v) => typeof v === 'string' && USER_ID_RE.test(v);
const isValidUuid = (v) => typeof v === 'string' && UUID_RE.test(v);
const isValidOpaqueId = (v) => typeof v === 'string' && OPAQUE_ID_RE.test(v);
const isValidUInt32 = (v) => Number.isInteger(v) && v >= 0 && v <= 0xffffffff;

function validateBundleUpload(body) {
  if (!body || typeof body !== 'object') return 'malformed body';
  if (!isValidUuid(body.userId)) return 'invalid userId';
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

function validateEnvelope(body) {
  if (!body || typeof body !== 'object') return 'malformed body';
  if (!isValidOpaqueId(body.id)) return 'invalid id';
  if (!isValidOpaqueId(body.conversationId)) return 'invalid conversationId';
  if (!isValidUserId(body.senderId)) return 'invalid senderId';
  if (!isValidUserId(body.recipientId)) return 'invalid recipientId';
  if (body.kind !== 'handshake' && body.kind !== 'ratchet') return 'invalid kind';
  if (!isValidBase64(body.ratchetMessage)
      || Buffer.from(body.ratchetMessage, 'base64').length > MAX_RATCHET_MESSAGE_BYTES) {
    return 'invalid or oversized ratchetMessage';
  }
  if (!ALLOWED_CONTENT_TYPES.includes(body.contentType)) return 'invalid contentType';

  if (body.createdAt !== undefined && body.createdAt !== null) {
    if (typeof body.createdAt !== 'string' || body.createdAt.length > 40
        || !Number.isFinite(Date.parse(body.createdAt))) {
      return 'invalid createdAt';
    }
  }

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

/**
 * The envelope as it will be stored and relayed: only known fields (the old
 * code forwarded the whole request body, so unknown fields were relayed to the
 * recipient verbatim), and `createdAt` is the sender's time clamped so it can't
 * sit in the future and sort ahead of everything.
 * Call after `validateEnvelope` succeeded.
 */
function normalizeEnvelope(body, nowMs = Date.now()) {
  let createdMs = body.createdAt ? Date.parse(body.createdAt) : nowMs;
  createdMs = Math.min(createdMs, nowMs + MAX_CLOCK_SKEW_MS);

  let handshake = null;
  if (body.kind === 'handshake') {
    const h = body.handshake;
    handshake = {
      identityAgreementKey: h.identityAgreementKey,
      identitySigningKey: h.identitySigningKey,
      senderUsername: h.senderUsername ?? null,
      ephemeralPublicKey: h.ephemeralPublicKey,
      usedSignedPreKeyId: h.usedSignedPreKeyId,
      usedOneTimePreKeyId: h.usedOneTimePreKeyId ?? null,
    };
  }

  return {
    id: body.id,
    conversationId: body.conversationId,
    senderId: body.senderId,
    recipientId: body.recipientId,
    kind: body.kind,
    handshake,
    ratchetMessage: body.ratchetMessage,
    contentType: body.contentType,
    createdAt: new Date(createdMs).toISOString(),
  };
}

module.exports = {
  X25519_KEY_BYTES,
  ED25519_KEY_BYTES,
  ED25519_SIGNATURE_BYTES,
  MAX_MEDIA_BYTES,
  ALLOWED_CONTENT_TYPES,
  isValidUsername,
  isValidUserId,
  isValidUuid,
  isValidOpaqueId,
  isValidUInt32,
  validateBundleUpload,
  validateSignedPreKeyUpload,
  validateOneTimePreKeyBatch,
  validateEnvelope,
  normalizeEnvelope,
};
