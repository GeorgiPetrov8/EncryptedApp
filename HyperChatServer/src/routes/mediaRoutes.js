'use strict';

const crypto = require('node:crypto');
const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { MAX_MEDIA_BYTES } = require('../validate');

/**
 * POST /media
 * Auth required. Body: raw bytes (already AES-256-GCM encrypted client-side
 * by `MediaEncryptionService.prepareForSending` — this server only ever
 * sees ciphertext and never holds the per-file key, which travels inside the
 * message envelope instead).
 * -> MediaUploadResult { mediaId }
 *
 * Stored as a BLOB in SQLite here, which is the right amount of
 * infrastructure for a scaffold. At real scale, swap this for object storage
 * (S3/GCS/R2) with this endpoint issuing a pre-signed upload URL instead of
 * proxying the bytes itself — the route contract (`{ mediaId }` in,
 * `{ mediaId }` out) doesn't need to change for that, only what happens
 * inside this handler.
 */
function uploadMediaRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.media, req, res)) return;

    const declaredLength = Number(req.headers['content-length'] || 0);
    if (declaredLength > MAX_MEDIA_BYTES) {
      return sendError(res, 413, 'payloadTooLarge', `Media must be under ${MAX_MEDIA_BYTES} bytes`);
    }

    let data;
    try {
      data = await readBody(req, { raw: true, maxBytes: MAX_MEDIA_BYTES });
    } catch (err) {
      return sendError(res, err.statusCode || 400, 'badRequest', err.message);
    }
    if (data.length === 0) return sendError(res, 400, 'badRequest', 'empty upload');

    const mediaId = crypto.randomUUID();
    store.stmt.insertMedia.run(mediaId, data, data.length, nowIso());
    sendJson(res, 201, { mediaId });
  };
}

/**
 * GET /media/:mediaId
 * Auth required (any valid session — media ids are unguessable UUIDs and
 * the decryption key never touches this server, so the access control that
 * matters is already cryptographic; this check mainly keeps the endpoint
 * from being an anonymous blob-hosting service).
 * -> raw bytes, Content-Type: application/octet-stream
 */
function downloadMediaRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.media, req, res)) return;

    const row = store.stmt.mediaById.get(req.params.mediaId);
    if (!row) return sendError(res, 404, 'mediaNotFound', 'That attachment is no longer available.');

    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': row.size_bytes,
    });
    res.end(row.data);
  };
}

module.exports = { uploadMediaRoute, downloadMediaRoute };
