# Server-side attachment blocking — what is actually possible

You asked for the server to reject or delete `.exe` uploads. There is a hard
architectural obstacle here that I want to state plainly rather than ship
something that looks like it works.

---

## The obstacle, measured

`MediaEncryptionService.prepareForSending` encrypts every attachment with
AES-256-GCM **on the device**, before `uploadMedia` is called. The server
receives ciphertext and never sees the key — that is the entire point of the
E2EE design.

I checked what that leaves visible. The same `.exe` and `.pdf`, before and
after encryption:

```
plaintext, first 8 bytes
  exe: 4d5a13646ba1b7d2   <- "MZ", trivially detectable
  pdf: 255044462d312e37   <- "%PDF"

what the server actually receives
  exe -> 64c941bf19df22fe
  pdf -> 8a37da2e47ad22f8
  exe -> 858776c0502a951f     (different every time — random IV)
  pdf -> 136afb9c2e4b49dc
```

Shannon entropy of the ciphertext: **7.912** bits/byte for the exe, **7.904**
for the pdf, out of a maximum of 8. The 0.008 difference is sampling noise and
carries no file-type information.

**A server-side content check on encrypted bytes cannot work.** Any code that
claimed to do it would be theatre — it would pass every upload, including the
ones it purported to block.

---

## What to do instead

Three layers, none of which pretends to be something it isn't.

### Layer 1 — Sender-side, by content (the real filter)

`AttachmentPolicy.inspect` runs before encryption, on plaintext bytes, and uses
an **allow-list** of magic signatures. Measured results:

| File renamed to `invoice.pdf` | extension check | magic-byte check |
|---|---|---|
| Windows PE | pass | **block** |
| ELF | pass | **block** |
| Mach-O (all 4 variants) | pass | **block** |
| Fat binary / Java class | pass | **block** |
| Shebang script | pass | **block** |

An allow-list rather than a deny-list, because a deny-list leaks. I tested:

| Format | Caught by signature deny-list? |
|---|---|
| `.scr` (PE, renamed) | yes |
| `.com` (DOS) | **no** — no fixed magic |
| `.jar` (ZIP) | **no** — identical container to `.docx` |
| `.msi` (OLE) | **no** — same container as legacy `.doc` |

The allow-list refuses all four by default, and `.jar` specifically is caught
by the ZIP-container inspection (`META-INF/MANIFEST.MF`).

### Layer 2 — Recipient-side, at decrypt (the layer that matters)

**This is the important one.** Layer 1 runs on the attacker's own device, so a
modified client skips it. The recipient's device is not under the attacker's
control, so re-running the identical check after decryption is a genuine
second boundary, not a duplicate.

```swift
// In MediaEncryptionService.decryptMedia, after AESGCM.open:
let plaintext = try AESGCM.open(ciphertext: encryptedFile, key: key)

switch AttachmentPolicy.inspect(data: plaintext, declaredExtension: payload.fileExtension) {
case .success:
    return plaintext
case .failure(let rejection):
    // A sender that bypassed the client-side check. The bytes never reach
    // the file system and never get a shareable URL.
    logger.fault("Rejected an inbound attachment: \(rejection.localizedDescription, privacy: .public)")
    cache.remove(mediaId: payload.mediaId)
    throw rejection
}
```

### Layer 3 — Server-side, structural only

The server can't inspect content, but it can enforce things that don't require
seeing plaintext. These are worth having; they are just not "blocking .exe".

```js
// src/routes/mediaRoutes.js — in uploadMediaRoute

// 1. Size ceiling, checked before buffering the body.
if (declaredLength > MAX_MEDIA_BYTES) {
  return sendError(res, 413, 'payloadTooLarge', `Media must be under ${MAX_MEDIA_BYTES} bytes`);
}

// 2. Reject anything that is NOT ciphertext.
//
// This is the one content-ish check that survives E2EE. A correctly encrypted
// blob is indistinguishable from random: entropy ~7.9+ bits/byte. A plaintext
// .exe uploaded by a broken or hostile client scores far lower (PE files are
// full of padding and repeated opcodes). This does not detect "an encrypted
// exe" — nothing can — but it does catch a client that skipped encryption
// entirely, which would otherwise leak plaintext into server storage.
const entropy = shannonEntropy(data.subarray(0, 8192));
if (entropy < 7.0) {
  return sendError(res, 400, 'badRequest', 'Attachment is not correctly encrypted.');
}

function shannonEntropy(buf) {
  const counts = new Uint32Array(256);
  for (const b of buf) counts[b]++;
  let h = 0;
  for (const c of counts) {
    if (!c) continue;
    const p = c / buf.length;
    h -= p * Math.log2(p);
  }
  return h;
}
```

```js
// 3. Orphan sweep. An uploaded blob whose message envelope never arrived is
//    unreferenced and unreachable — nobody holds its key. Keeping it is pure
//    storage cost and, if it ever were plaintext, pure liability.
//
// src/db.js
CREATE INDEX IF NOT EXISTS idx_media_created ON media_blobs(created_at);

// Run alongside the existing session/rate-limiter housekeeping in server.js:
const ORPHAN_TTL_MS = 24 * 60 * 60 * 1000;
store.db.prepare(`
  DELETE FROM media_blobs
  WHERE created_at < ?
    AND media_id NOT IN (
      SELECT DISTINCT json_extract(ratchet_message, '$.mediaId')
      FROM pending_envelopes
      WHERE json_valid(ratchet_message)
    )
`).run(new Date(Date.now() - ORPHAN_TTL_MS).toISOString());
```

Note the subquery can't actually find `mediaId` — it's inside the ciphertext.
In practice the orphan rule has to be time-based alone: a blob older than the
queue retention window with no corresponding undelivered envelope is
unreachable regardless. Simpler and honest:

```js
store.db.prepare(
  `DELETE FROM media_blobs WHERE created_at < ?`
).run(new Date(Date.now() - MEDIA_RETENTION_MS).toISOString());
```

with `MEDIA_RETENTION_MS` set comfortably longer than the pending-envelope
retention, so a recipient who is offline for a while can still fetch.

---

## If you genuinely need server-side content scanning

The only way is to give up E2EE for attachments — upload plaintext, let the
server scan it, and accept that the server can read every file anyone sends.
That is the trade WhatsApp and Signal both decline to make, and I'd decline it
here too: the app's entire premise is that the server sees nothing.

A middle option some products use is **client-attested scanning**: the sender's
device runs the check and signs an attestation, which the server records. It
raises the cost of bypass but does not prevent it — a modified client signs
whatever it likes. Worth knowing it exists; not worth the complexity here,
because Layer 2 already gives the recipient a check the attacker can't skip.
