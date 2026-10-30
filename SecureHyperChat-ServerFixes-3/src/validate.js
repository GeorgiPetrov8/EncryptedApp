'use strict';

const { isValidBase64 } = require('./json');
const { verifyEd25519 } = require('./challenge');

/**
 * Server-side shape validation. The server never uses these bytes
 * cryptographically for messages, but it can cheaply reject malformed or
 * oversized values before they're stored or relayed.
 */
const X25519_KEY_BYTES = 32;
const ED25519_KEY_BYTES = 32;
const ED25519_SIGNATURE_BYTES = 64;

const USERNAME_RE = /^[a-zA-Z0-9_.-]{3,32}$/;
const USER_ID_RE = /^[a-zA-Z0-9-]{1,64}$/;
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const OPAQUE_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;

/** Keep in sync with `EnvelopePayloadKind` in DTOs.swift. */
const ALLOWED_CONTENT_TYPES = [
  'text', 'image', 'video', 'file',
  'notePad', 'receipt', 'profile', 'invite', 'call', 'edit', 'reaction',
];

const MAX_RATCHET_MESSAGE_BYTES = 256 * 1024;
const MAX_MEDIA_BYTES = 25 * 1024 * 1024;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;

const isValidUsername = (v) => typeof v === 'string' && USERNAME_RE.test(v);
const isValidUserId = (v) => typeof v === 'string' && USER_ID_RE.test(v);
const isValidUuid = (v) => typeof v === 'string' && UUID_RE.test(v);
const isValidOpaqueId = (v) => typeof v === 'string' && OPAQUE_ID_RE.test(v);
const isValidUInt32 = (v) => Number.isInteger(v) && v >= 0 && v <= 0xffffffff;

/**
 * FIX (S14): the signed prekey's signature is checked against the identity
 * signing key on the server too — a second line of defence behind the client's
 * own check, and it stops garbage from being stored and handed to every peer.
 *
 * The app signs the raw 32-byte X25519 public key (Signal's construction). Modes
 * (`SPK_SIGNATURE_CHECK`):
 *   "enforce"  reject on mismatch
 *   "warn"     (default) log and accept — use this first, check the log after a
 *              registration from the real app, then switch to "enforce"
 *   "off"      no check
 *
 * Returns an error string, or null.
 */
function checkSignedPreKeySignature(identitySigningKey, signedPreKey, signature, context) {
  const mode = process.env.SPK_SIGNATURE_CHECK || 'warn';
  if (mode === 'off') return null;
  const ok = verifyEd25519(identitySigningKey, Buffer.from(signedPreKey, 'base64'), signature)
    || verifyEd25519(identitySigningKey, Buffer.concat([Buffer.from('SHC-spk-v1', 'utf8'), Buffer.from(signedPreKey, 'base64')]), signature);
  if (ok) return null;
  if (mode === 'enforce') return 'signedPreKeySignature does not verify';
  console.warn(`[validate] signed prekey signature did not verify (${context}); accepted because SPK_SIGNATURE_CHECK=warn`);
  return null;
}

function validateBundleUpload(body) {
  if (!body || typeof body !== 'object') return 'malformed body';
  if (!isValidUuid(body.userId)) return 'invalid userId';
  if (!isValidUsername(body.username)) return 'invalid username';
  if (!isValidBase64(body.identityAgreementKey, { exactByteLength: X25519_KEY_BYTES })) return 'invalid identityAgreementKey';
  if (!isValidBase64(body.identitySigningKey, { exactByteLength: ED25519_KEY_BYTES })) return 'invalid identitySigningKey';
  if (!isValidUInt32(body.signedPreKeyId)) return 'invalid signedPreKeyId';
  if (!isValidBase64(body.signedPreKey, { exactByteLength: X25519_KEY_BYTES })) return 'invalid signedPreKey';
  if (!isValidBase64(body.signedPreKeySignature, { exactByteLength: ED25519_SIGNATURE_BYTES })) return 'invalid signedPreKeySignature';
  if (!Array.isArray(body.oneTimePreKeys) || body.oneTimePreKeys.length > 200) return 'invalid oneTimePreKeys';
  const ids = new Set();
  for (const otk of body.oneTimePreKeys) {
    if (!otk || !isValidUInt32(otk.id)) return 'invalid one-time prekey id';
    if (ids.has(otk.id)) return 'duplicate one-time prekey id';
    ids.add(otk.id);
    if (!isValidBase64(otk.publicKey, { exactByteLength: X25519_KEY_BYTES })) return 'invalid one-time prekey publicKey';
  }
  return checkSignedPreKeySignature(body.identitySigningKey, body.signedPreKey, body.signedPreKeySignature, 'bundle');
}

/** `identitySigningKey` comes from the stored account. */
function validateSignedPreKeyUpload(body, identitySigningKey) {
  if (!body || typeof body !== 'object') return 'malformed body';
  if (!isValidUserId(body.userId)) return 'invalid userId';
  if (!isValidUInt32(body.signedPreKeyId)) return 'invalid signedPreKeyId';
  if (!isValidBase64(body.signedPreKey, { exactByteLength: X25519_KEY_BYTES })) return 'invalid signedPreKey';
  if (!isValidBase64(body.signedPreKeySignature, { exactByteLength: ED25519_SIGNATURE_BYTES })) return 'invalid signedPreKeySignature';
  if (identitySigningKey) {
    return checkSignedPreKeySignature(identitySigningKey, body.signedPreKey, body.signedPreKeySignature, 'rotation');
  }
  return null;
}

function validateOneTimePreKeyBatch(body) {
  if (!body || !Array.isArray(body.keys) || body.keys.length === 0 || body.keys.length > 200) return 'invalid keys';
  for (const otk of body.keys) {
    if (!otk || !isValidUInt32(otk.id)) return 'invalid one-time prekey id';
    if (!isValidBase64(otk.publicKey, { exactByteLength: X25519_KEY_BYTES })) return 'invalid one-time prekey publicKey';
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
    if (typeof body.createdAt !== 'string' || body.createdAt.length > 40 || !Number.isFinite(Date.parse(body.createdAt))) {
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
 * The envelope as stored and relayed: only known fields, `createdAt` clamped.
 *
 * FIX (S1): `senderUsername` in a handshake is replaced with the sender's real,
 * server-registered username. It used to be relayed exactly as the sender typed
 * it, so older apps that still display it could be shown any name.
 */
function normalizeEnvelope(body, { senderUsername } = {}, nowMs = Date.now()) {
  let createdMs = body.createdAt ? Date.parse(body.createdAt) : nowMs;
  createdMs = Math.min(createdMs, nowMs + MAX_CLOCK_SKEW_MS);

  let handshake = null;
  if (body.kind === 'handshake') {
    const h = body.handshake;
    handshake = {
      identityAgreementKey: h.identityAgreementKey,
      identitySigningKey: h.identitySigningKey,
      senderUsername: senderUsername ?? null,
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
  checkSignedPreKeySignature,
  validateBundleUpload,
  validateSignedPreKeyUpload,
  validateOneTimePreKeyBatch,
  validateEnvelope,
  normalizeEnvelope,
};
