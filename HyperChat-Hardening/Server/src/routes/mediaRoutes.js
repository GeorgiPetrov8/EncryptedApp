'use strict';

const crypto = require('node:crypto');
const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { MAX_MEDIA_BYTES } = require('../validate');

const MEDIA_ID_RE = /^[0-9a-fA-F-]{36}$/;
const quotaBytes = () => Number(process.env.MEDIA_QUOTA_BYTES) || 500 * 1024 * 1024;

/**
 * POST /media — auth required. Body: raw bytes, already AES-256-GCM encrypted
 * on the device; the server only ever sees ciphertext and never the key.
 * -> { mediaId }
 *
 * Each account has a quota of bytes it may have stored at once, so one login can
 * no longer fill the disk. Files expire server-side (MEDIA_RETENTION_DAYS) and
 * are removed with their account.
 *
 * Stored as a BLOB in SQLite, which is right for a scaffold; for large albums
 * move to files on disk or object storage — the `{ mediaId }` contract holds.
 */
function uploadMediaRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.media, req, res)) return;

    const declared = Number(req.headers['content-length']);
    const declaredBytes = Number.isFinite(declared) ? declared : 0;
    if (declaredBytes > MAX_MEDIA_BYTES) {
      return sendError(res, 413, 'payloadTooLarge', `Media must be under ${MAX_MEDIA_BYTES} bytes`);
    }

    const used = store.stmt.mediaBytesForUploader.get(req.userId).n;
    if (used + declaredBytes > quotaBytes()) {
      return sendError(res, 413, 'quotaExceeded', 'Your storage on the server is full. Try again after your earlier files have been delivered.');
    }

    const data = await readBody(req, { raw: true, maxBytes: MAX_MEDIA_BYTES });
    if (data.length === 0) return sendError(res, 400, 'badRequest', 'empty upload');
    if (used + data.length > quotaBytes()) {
      return sendError(res, 413, 'quotaExceeded', 'Your storage on the server is full.');
    }

    const mediaId = crypto.randomUUID();
    store.stmt.insertMedia.run(mediaId, data, data.length, nowIso(), req.userId);
    sendJson(res, 201, { mediaId });
  };
}

/**
 * GET /media/:mediaId — auth required (any valid session; ids are unguessable
 * UUIDs and the key never touches this server, so the access control that
 * matters is cryptographic).
 */
function downloadMediaRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.media, req, res)) return;
    if (!MEDIA_ID_RE.test(req.params.mediaId)) {
      return sendError(res, 404, 'mediaNotFound', 'That attachment is no longer available.');
    }
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
