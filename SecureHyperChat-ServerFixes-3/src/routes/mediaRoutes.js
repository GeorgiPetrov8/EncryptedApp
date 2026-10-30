'use strict';

const crypto = require('node:crypto');
const { sendJson, sendError, nowIso, SECURITY_HEADERS } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { MAX_MEDIA_BYTES } = require('../validate');

const MEDIA_ID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const quotaBytes = () => Number(process.env.MEDIA_QUOTA_BYTES) || 500 * 1024 * 1024;

/**
 * POST /media — raw, client-encrypted bytes -> { mediaId }
 *
 * FIX (S16): the server keeps files no longer than needed.
 *   Header `X-Media-Recipients: <n>` (1–50): the file is deleted as soon as `n`
 *   downloads by accounts OTHER than the uploader have happened — for a 1:1 chat
 *   message that's the moment the recipient fetched it. Without the header
 *   (avatars, older apps) the file stays until MEDIA_RETENTION_DAYS.
 * The quota message no longer promises a cleanup that wasn't happening.
 */
function uploadMediaRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.media, req, res)) return;

    const declared = Number(req.headers['content-length']);
    const declaredBytes = Number.isFinite(declared) ? declared : 0;
    if (declaredBytes > MAX_MEDIA_BYTES) {
      return sendError(res, 413, 'payloadTooLarge', `Media must be under ${Math.floor(MAX_MEDIA_BYTES / 1048576)} MB`);
    }

    const used = store.stmt.mediaBytesForUploader.get(req.userId).n;
    const quotaMessage = 'Your storage on the server is full. Files are removed once they have been delivered, or after a while — try again later.';
    if (used + declaredBytes > quotaBytes()) return sendError(res, 413, 'quotaExceeded', quotaMessage);

    const data = await readBody(req, { raw: true, maxBytes: MAX_MEDIA_BYTES });
    if (data.length === 0) return sendError(res, 400, 'badRequest', 'empty upload');
    if (used + data.length > quotaBytes()) return sendError(res, 413, 'quotaExceeded', quotaMessage);

    const recipientsHeader = Number(req.headers['x-media-recipients']);
    const maxDownloads = Number.isInteger(recipientsHeader) && recipientsHeader >= 1 && recipientsHeader <= 50
      ? recipientsHeader
      : null;

    const mediaId = crypto.randomUUID();
    store.stmt.insertMedia.run(mediaId, data, data.length, nowIso(), req.userId, maxDownloads);
    sendJson(res, 201, { mediaId });
  };
}

/** GET /media/:mediaId */
function downloadMediaRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.media, req, res)) return;
    if (!MEDIA_ID_RE.test(req.params.mediaId)) {
      return sendError(res, 404, 'mediaNotFound', 'That attachment is no longer available.');
    }
    const mediaId = req.params.mediaId.toLowerCase();
    const row = store.stmt.mediaById.get(mediaId);
    if (!row) return sendError(res, 404, 'mediaNotFound', 'That attachment is no longer available.');

    res.writeHead(200, {
      ...SECURITY_HEADERS,
      'Content-Type': 'application/octet-stream',
      'Content-Length': row.size_bytes,
    });
    res.end(row.data);

    // Counted once the response has actually been sent; the uploader fetching
    // their own file doesn't count.
    if (row.max_downloads && req.userId !== row.uploader_id) {
      res.once('finish', () => {
        try {
          const counted = store.stmt.bumpMediaDownload.get(mediaId);
          if (counted && counted.max_downloads && counted.download_count >= counted.max_downloads) {
            store.stmt.deleteMediaById.run(mediaId);
          }
        } catch (err) {
          console.error('[media] download bookkeeping failed:', err.message);
        }
      });
    }
  };
}

module.exports = { uploadMediaRoute, downloadMediaRoute };
