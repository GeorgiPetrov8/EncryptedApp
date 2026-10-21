'use strict';

const crypto = require('node:crypto');
const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { requireAuth, issueToken } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { validateBundleUpload } = require('../validate');
const { consumeChallenge } = require('../challenge');
const mailer = require('../mailer'); // referenced via the module so tests can capture mail

/**
 * Account recovery: a verified recovery email, an optional encrypted backup
 * stored on the server, and two ways back in on a new device.
 *
 * What the server can and can't do here:
 *   - It never sees backup contents: the client encrypts with a key derived
 *     from the user's password before upload.
 *   - An email code yields a short-lived "recovery ticket". A ticket can
 *     (a) download the encrypted backup (useless without the password) or
 *     (b) REPLACE THE ACCOUNT'S IDENTITY KEYS via /recovery/rebind and receive a
 *     new session. (b) is the dangerous one — contacts see "security keys
 *     changed", but the account itself is taken over. That is why the recovery
 *     email can no longer be set or changed with a bearer token alone: it needs
 *     a signature from the device's identity key.
 */
const CODE_TTL_MS = 10 * 60 * 1000;
const CODE_MAX_ATTEMPTS = 5;
const CODE_RESEND_COOLDOWN_MS = 60 * 1000;
const TICKET_TTL_MS = 15 * 60 * 1000;
const MAX_BACKUP_BYTES = 50 * 1024 * 1024;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const sha256 = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');

// --- code hashing ----------------------------------------------------------
// A 6-digit code has 1,000,000 values, so an unkeyed hash is worthless: from a
// leaked database it falls in about a second. HMAC with a server secret makes the
// stored hash useless without that secret.
let developmentSecret = null;
function codeSecret() {
  if (process.env.CODE_SECRET) return process.env.CODE_SECRET;
  if (process.env.NODE_ENV === 'production') {
    throw new Error('CODE_SECRET is required in production (openssl rand -hex 32)');
  }
  developmentSecret ??= crypto.randomBytes(32).toString('hex'); // codes don't survive a restart; fine in dev
  return developmentSecret;
}
/** Call at startup so a missing secret stops the server instead of failing later. */
function assertConfigured() {
  codeSecret();
}
const codeHash = (userId, purpose, code) =>
  crypto.createHmac('sha256', codeSecret()).update(`${userId}:${purpose}:${code}`).digest('hex');
const newCode = () => String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');

function normalizeEmail(value) {
  if (typeof value !== 'string') return null;
  const email = value.trim().toLowerCase();
  return email.length <= 254 && EMAIL_RE.test(email) ? email : null;
}

function maskEmail(email) {
  const [local, domain] = email.split('@');
  return `${local.slice(0, 1)}${'•'.repeat(Math.max(1, local.length - 1))}@${domain}`;
}

/**
 * Issues a fresh code. Returns `{ code }` or `{ error: 'cooldown' | 'tooMany' }`.
 * Bounded per account, so the endpoint can't be used to flood an inbox.
 */
function issueCode(store, limiters, userId, purpose, email) {
  const existing = store.stmt.codeFor.get(userId, purpose);
  if (existing && Date.now() - new Date(existing.created_at).getTime() < CODE_RESEND_COOLDOWN_MS) {
    return { error: 'cooldown' };
  }
  if (!limiters.codesPerAccount.take(`${userId}:${purpose}`)) return { error: 'tooMany' };

  const code = newCode();
  const now = new Date();
  store.stmt.upsertCode.run(
    userId, purpose, codeHash(userId, purpose, code), email,
    now.toISOString(), new Date(now.getTime() + CODE_TTL_MS).toISOString(),
  );
  return { code };
}

/**
 * Checks a code. Single-use on success; burned after too many wrong tries, and
 * the number of checks per account per hour is bounded as well, so repeatedly
 * requesting fresh codes doesn't give an attacker unlimited guesses.
 * Returns the code row on success, or an error string.
 */
function checkCode(store, limiters, userId, purpose, code) {
  if (!limiters.codeChecks.take(`${userId}:${purpose}`)) return 'tooManyAttempts';

  const row = store.stmt.codeFor.get(userId, purpose);
  if (!row) return 'noCode';
  if (new Date(row.expires_at).getTime() < Date.now()) {
    store.stmt.deleteCode.run(userId, purpose);
    return 'expired';
  }
  if (row.attempts >= CODE_MAX_ATTEMPTS) {
    store.stmt.deleteCode.run(userId, purpose);
    return 'tooManyAttempts';
  }
  store.stmt.bumpCodeAttempts.run(userId, purpose);

  const expected = Buffer.from(row.code_hash, 'hex');
  const actual = Buffer.from(codeHash(userId, purpose, String(code ?? '')), 'hex');
  if (expected.length !== actual.length || !crypto.timingSafeEqual(expected, actual)) return 'wrongCode';
  store.stmt.deleteCode.run(userId, purpose);
  return row;
}

const codeErrorMessage = {
  noCode: 'Request a new code.',
  expired: 'That code has expired. Request a new one.',
  tooManyAttempts: 'Too many attempts. Request a new code.',
  wrongCode: 'That code is not correct.',
};

function ticketUser(store, ticket) {
  if (typeof ticket !== 'string' || !ticket || ticket.length > 200) return null;
  const hash = sha256(ticket);
  const row = store.stmt.ticketByHash.get(hash);
  if (!row) return null;
  if (new Date(row.expires_at).getTime() < Date.now()) {
    store.stmt.deleteTicket.run(hash);
    return null;
  }
  return { userId: row.user_id, hash };
}

// ---------------------------------------------------------------------------
// Signed-in: manage the recovery email
// ---------------------------------------------------------------------------

/** GET /account/email -> { email, verified, pendingEmail, backup, mailConfigured } */
function getEmailRoute(store) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    const row = store.stmt.emailForUser.get(req.userId);
    const pending = store.stmt.codeFor.get(req.userId, 'verify');
    const backup = store.stmt.backupInfoForUser.get(req.userId);
    sendJson(res, 200, {
      email: row ? row.email : null,
      verified: row ? row.verified === 1 : false,
      pendingEmail: pending ? pending.email : null,
      backup: backup ? { sizeBytes: backup.size_bytes, updatedAt: backup.updated_at } : null,
      // Lets the app say "email isn't available on this server" instead of
      // reporting a code as sent when nothing was.
      mailConfigured: mailer.isConfigured(),
    });
  };
}

/**
 * POST /account/email { email, nonce, signature } -> 202
 *
 * `nonce` comes from POST /account/challenge and `signature` is the device's
 * identity key signing it. Without that, anyone holding a leaked bearer token
 * could add their own address (an account with no verified email has nobody to
 * warn), confirm it, and take the account over through /recovery/rebind.
 *
 * Sends a code to the NEW address; it only becomes the recovery email once that
 * code is confirmed. If a verified address already exists it gets a notice.
 * (ALLOW_UNSIGNED_EMAIL_CHANGE=1 skips the signature during an app roll-out.)
 */
function setEmailRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    const email = normalizeEmail(body.email);
    if (!email) return sendError(res, 400, 'badRequest', 'That email address is not valid.');

    const account = store.stmt.accountById.get(req.userId);
    if (process.env.ALLOW_UNSIGNED_EMAIL_CHANGE !== '1') {
      if (typeof body.nonce !== 'string' || typeof body.signature !== 'string') {
        return sendError(res, 401, 'proofRequired',
          'Confirm this change with this device\'s key. Update the app and try again.');
      }
      const proof = consumeChallenge(store, account, body.nonce, body.signature);
      if (!proof.ok) {
        return sendError(res, proof.code === 'badRequest' ? 400 : 401, proof.code, proof.message);
      }
    }

    if (!limiters.emailPerAddress.take(email)) {
      return sendError(res, 429, 'rateLimited', 'Too many codes were sent to that address. Try again later.');
    }

    const issued = issueCode(store, limiters, req.userId, 'verify', email);
    if (issued.error === 'cooldown') {
      return sendError(res, 429, 'rateLimited', 'Wait a minute before requesting another code.');
    }
    if (issued.error) {
      return sendError(res, 429, 'rateLimited', 'Too many codes requested. Try again later.');
    }

    await mailer.sendMail({
      to: email,
      subject: 'SecureHyperChat verification code',
      text: `Your SecureHyperChat code is ${issued.code}.\nIt expires in 10 minutes. If you didn't ask for it, ignore this email.`,
    });

    const current = store.stmt.emailForUser.get(req.userId);
    if (current && current.verified === 1 && current.email !== email) {
      await mailer.sendMail({
        to: current.email,
        subject: 'SecureHyperChat recovery email change requested',
        text: `Someone signed in as "${account.username}" asked to change the recovery email to ${maskEmail(email)}.\nIf that wasn't you, your phone may be in someone else's hands.`,
      });
    }
    sendJson(res, 202, { sentTo: email });
  };
}

/** POST /account/email/verify { code } -> { email, verified: true } */
function verifyEmailRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    const result = checkCode(store, limiters, req.userId, 'verify', body.code);
    if (typeof result === 'string') {
      return sendError(res, 400, result, codeErrorMessage[result]);
    }
    store.stmt.upsertVerifiedEmail.run(req.userId, result.email, nowIso());
    sendJson(res, 200, { email: result.email, verified: true });
  };
}

/** POST /account/email/remove -> 204. Also deletes the server backup, which can
 *  no longer be retrieved without a recovery email. */
function removeEmailRoute(store) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    store.transaction(() => {
      store.stmt.deleteEmail.run(req.userId);
      store.stmt.deleteCode.run(req.userId, 'verify');
      store.stmt.deleteBackup.run(req.userId);
    });
    res.writeHead(204).end();
  };
}

// ---------------------------------------------------------------------------
// Signed-in: encrypted backup
// ---------------------------------------------------------------------------

/** POST /backup  (raw bytes, already encrypted by the client) -> 204 */
function uploadBackupRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.media, req, res)) return;
    const email = store.stmt.emailForUser.get(req.userId);
    if (!email || email.verified !== 1) {
      return sendError(res, 409, 'emailRequired', 'Add and verify a recovery email first.');
    }
    let data;
    try {
      data = await readBody(req, { raw: true, maxBytes: MAX_BACKUP_BYTES });
    } catch (err) {
      if (err.statusCode === 413) return sendError(res, 413, 'payloadTooLarge', 'Backup is larger than 50 MB.');
      throw err;
    }
    // The client format starts with the magic "HCBK". Refusing anything else
    // stops the endpoint being used as free storage.
    if (data.length < 64 || data.subarray(0, 4).toString('latin1') !== 'HCBK') {
      return sendError(res, 400, 'badRequest', 'Not a SecureHyperChat backup.');
    }
    store.stmt.upsertBackup.run(req.userId, data, data.length, nowIso());
    res.writeHead(204).end();
  };
}

/** POST /backup/delete -> 204 */
function deleteBackupRoute(store) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    store.stmt.deleteBackup.run(req.userId);
    res.writeHead(204).end();
  };
}

// ---------------------------------------------------------------------------
// Signed-out: recovery on a new device
// ---------------------------------------------------------------------------

/**
 * POST /recovery/start { username } -> 202 { sent: true }
 * Always the same answer, whether or not the username exists or has an email,
 * and the mail is sent in the background so the response time doesn't differ
 * either.
 */
function startRecoveryRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    const account = typeof body.username === 'string' ? store.stmt.accountByUsername.get(body.username) : null;
    const email = account ? store.stmt.emailForUser.get(account.user_id) : null;

    if (account && email && email.verified === 1) {
      const issued = issueCode(store, limiters, account.user_id, 'recover', email.email);
      if (issued.code) {
        mailer.sendMail({
          to: email.email,
          subject: 'SecureHyperChat account recovery',
          text: `Your SecureHyperChat recovery code is ${issued.code}.\nIt expires in 10 minutes.\nIf you didn't try to recover "${account.username}", ignore this email — nobody can get in without the code.`,
        }).catch(() => {});
      }
    }
    sendJson(res, 202, { sent: true });
  };
}

/**
 * POST /recovery/verify { username, code }
 *   -> { ticket, userId, username, hasBackup, backupUpdatedAt }
 */
function verifyRecoveryRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    const account = typeof body.username === 'string' ? store.stmt.accountByUsername.get(body.username) : null;
    if (!account) return sendError(res, 400, 'wrongCode', codeErrorMessage.wrongCode);

    const result = checkCode(store, limiters, account.user_id, 'recover', body.code);
    if (typeof result === 'string') {
      return sendError(res, 400, result, codeErrorMessage[result]);
    }

    store.stmt.deleteExpiredTickets.run(nowIso());
    const ticket = crypto.randomBytes(32).toString('base64url');
    store.stmt.insertTicket.run(
      sha256(ticket), account.user_id, new Date(Date.now() + TICKET_TTL_MS).toISOString(),
    );
    const backup = store.stmt.backupInfoForUser.get(account.user_id);
    sendJson(res, 200, {
      ticket,
      userId: account.user_id,
      username: account.username,
      hasBackup: Boolean(backup),
      backupUpdatedAt: backup ? backup.updated_at : null,
    });
  };
}

/** GET /recovery/backup  (header X-Recovery-Ticket) -> raw encrypted backup */
function downloadBackupRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.auth, req, res)) return;
    const ticket = ticketUser(store, req.headers['x-recovery-ticket']);
    if (!ticket) return sendError(res, 401, 'invalidTicket', 'Recovery session expired. Start again.');
    const backup = store.stmt.backupForUser.get(ticket.userId);
    if (!backup) return sendError(res, 404, 'noBackup', 'There is no backup on the server.');
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': backup.size_bytes,
    });
    res.end(Buffer.from(backup.data));
  };
}

/**
 * POST /recovery/rebind { ticket, bundle } -> AuthToken
 *
 * Recovery WITHOUT the backup password: the account keeps its username but gets
 * brand-new keys. Old history can't come back, and every contact sees "security
 * keys changed".
 *
 * Whatever was signed in before is cut off: sessions are deleted AND the old
 * device's open WebSocket is closed, its push tokens and ntfy topic removed —
 * otherwise it kept receiving the account's notifications.
 *
 * @param deps `{ presence, ntfy }`
 */
function rebindRoute(store, limiters, deps = {}) {
  return async (req, res) => {
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    const ticket = ticketUser(store, body.ticket);
    if (!ticket) return sendError(res, 401, 'invalidTicket', 'Recovery session expired. Start again.');

    const validationError = validateBundleUpload(body.bundle);
    if (validationError) return sendError(res, 400, 'badRequest', validationError);

    const account = store.stmt.accountById.get(ticket.userId);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');
    const bundle = body.bundle;
    if (bundle.userId !== account.user_id || bundle.username.toLowerCase() !== account.username.toLowerCase()) {
      return sendError(res, 400, 'badRequest', 'Bundle does not match the account being recovered.');
    }

    store.transaction(() => {
      store.stmt.replaceIdentity.run(
        bundle.identityAgreementKey, bundle.identitySigningKey,
        bundle.signedPreKeyId, bundle.signedPreKey, bundle.signedPreKeySignature,
        account.user_id,
      );
      store.stmt.deleteOneTimePreKeysForUser.run(account.user_id);
      for (const otk of bundle.oneTimePreKeys) {
        store.stmt.insertOneTimePreKey.run(account.user_id, otk.id, otk.publicKey);
      }
      // Everything queued was encrypted to the old keys and can never be read.
      store.stmt.deletePendingForRecipient.run(account.user_id);
      // Sign out every other device holding the old identity.
      store.stmt.deleteSessionsForUser.run(account.user_id);
      store.stmt.deleteAllDeviceTokensForUser.run(account.user_id);
      deps.ntfy?.removeTopic(account.user_id);
      // The old backup is encrypted to the old identity: useless now.
      store.stmt.deleteBackup.run(account.user_id);
      store.stmt.deleteTicket.run(ticket.hash);
    });
    deps.presence?.disconnect(account.user_id, 4003, 'account recovered on another device');

    const email = store.stmt.emailForUser.get(account.user_id);
    if (email) {
      mailer.sendMail({
        to: email.email,
        subject: 'SecureHyperChat account recovered on a new device',
        text: `"${account.username}" was recovered on a new device with new security keys.\nIf this wasn't you, contact support immediately.`,
      }).catch(() => {});
    }

    const token = issueToken(store, account.user_id);
    sendJson(res, 200, { userId: account.user_id, token });
  };
}

module.exports = {
  getEmailRoute,
  setEmailRoute,
  verifyEmailRoute,
  removeEmailRoute,
  uploadBackupRoute,
  deleteBackupRoute,
  startRecoveryRoute,
  verifyRecoveryRoute,
  downloadBackupRoute,
  rebindRoute,
  assertConfigured,
  // exported for tests
  _internal: { checkCode, issueCode, codeHash, normalizeEmail },
};
