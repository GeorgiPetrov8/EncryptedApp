'use strict';

const crypto = require('node:crypto');
const { sendJson, sendError, nowIso } = require('../json');
const { readBody } = require('../router');
const { requireAuth, issueToken } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { validateBundleUpload } = require('../validate');
const mailer = require('../mailer'); // referenced via the module so tests can capture mail

/**
 * Account recovery: a verified recovery email, an optional encrypted backup
 * stored on the server, and two ways back in on a new device.
 *
 * What the server can and can't do here:
 *   - It never sees backup contents. The client encrypts the backup with a
 *     password-derived key before upload; the server stores bytes.
 *   - An email code alone NEVER yields a messaging session. It yields a
 *     short-lived "recovery ticket" that can only (a) download the encrypted
 *     backup, which is useless without the password, or (b) replace the
 *     account's identity keys. (b) is visible to every contact as "security
 *     keys changed", which is exactly the warning they should get if someone
 *     hijacked the email.
 */

const CODE_TTL_MS = 10 * 60 * 1000;
const CODE_MAX_ATTEMPTS = 5;
const CODE_RESEND_COOLDOWN_MS = 60 * 1000;
const TICKET_TTL_MS = 15 * 60 * 1000;
const MAX_BACKUP_BYTES = 50 * 1024 * 1024;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const sha256 = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
const codeHash = (userId, purpose, code) => sha256(`${userId}:${purpose}:${code}`);
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

/** Issues a fresh code, respecting a resend cooldown. Returns the code or null. */
function issueCode(store, userId, purpose, email) {
  const existing = store.stmt.codeFor.get(userId, purpose);
  if (existing && Date.now() - new Date(existing.created_at).getTime() < CODE_RESEND_COOLDOWN_MS) {
    return null;
  }
  const code = newCode();
  const now = new Date();
  store.stmt.upsertCode.run(
    userId, purpose, codeHash(userId, purpose, code), email,
    now.toISOString(), new Date(now.getTime() + CODE_TTL_MS).toISOString(),
  );
  return code;
}

/**
 * Checks a code. Single-use on success; burned after too many attempts so a
 * 6-digit code can't be brute-forced (5 tries out of 1,000,000).
 * Returns the code row on success, or an error string.
 */
function checkCode(store, userId, purpose, code) {
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
  if (!crypto.timingSafeEqual(expected, actual)) return 'wrongCode';

  store.stmt.deleteCode.run(userId, purpose);
  return row;
}

const codeErrorMessage = {
  noCode: 'Request a new code.',
  expired: 'That code has expired. Request a new one.',
  tooManyAttempts: 'Too many attempts. Request a new code.',
  wrongCode: 'That code is not correct.',
};

function readRawBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        reject(Object.assign(new Error('too large'), { tooLarge: true }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function ticketUser(store, req) {
  const ticket = req.headers['x-recovery-ticket'];
  if (typeof ticket !== 'string' || !ticket) return null;
  const row = store.stmt.ticketByHash.get(sha256(ticket));
  if (!row) return null;
  if (new Date(row.expires_at).getTime() < Date.now()) {
    store.stmt.deleteTicket.run(sha256(ticket));
    return null;
  }
  return { userId: row.user_id, hash: sha256(ticket) };
}

// ---------------------------------------------------------------------------
// Signed-in: manage the recovery email
// ---------------------------------------------------------------------------

/** GET /account/email -> { email, verified, backup: { sizeBytes, updatedAt } | null } */
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
    });
  };
}

/**
 * POST /account/email { email } -> 202
 *
 * Sends a code to the NEW address. The address only becomes the recovery
 * email once that code is confirmed, so a typo can't lock anyone out. If a
 * verified address already exists, it gets a notice — that's the alarm bell
 * if someone with access to an unlocked phone tries to redirect recovery.
 */
function setEmailRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.auth, req, res)) return;

    const body = await readBody(req);
    const email = normalizeEmail(body.email);
    if (!email) return sendError(res, 400, 'badRequest', 'That email address is not valid.');

    const code = issueCode(store, req.userId, 'verify', email);
    if (!code) return sendError(res, 429, 'rateLimited', 'Wait a minute before requesting another code.');

    const account = store.stmt.accountById.get(req.userId);
    await mailer.sendMail({
      to: email,
      subject: 'HyperChat verification code',
      text: `Your HyperChat code is ${code}.\nIt expires in 10 minutes. If you didn't ask for it, ignore this email.`,
    });

    const current = store.stmt.emailForUser.get(req.userId);
    if (current && current.verified === 1 && current.email !== email) {
      await mailer.sendMail({
        to: current.email,
        subject: 'HyperChat recovery email change requested',
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
    const result = checkCode(store, req.userId, 'verify', body.code);
    if (typeof result === 'string') {
      return sendError(res, 400, result, codeErrorMessage[result]);
    }
    store.stmt.upsertVerifiedEmail.run(req.userId, result.email, nowIso());
    sendJson(res, 200, { email: result.email, verified: true });
  };
}

/** POST /account/email/remove -> 204. Also deletes the server backup, which
 *  can no longer be retrieved without a recovery email. */
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
      data = await readRawBody(req, MAX_BACKUP_BYTES);
    } catch (err) {
      if (err.tooLarge) return sendError(res, 413, 'payloadTooLarge', 'Backup is larger than 50 MB.');
      throw err;
    }
    // The client format starts with the magic "HCBK". Anything else is not
    // a backup — refusing it stops the endpoint being used as free storage.
    if (data.length < 64 || data.subarray(0, 4).toString('latin1') !== 'HCBK') {
      return sendError(res, 400, 'badRequest', 'Not a HyperChat backup.');
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
 *
 * Always the same response, whether or not the username exists or has an
 * email — otherwise this endpoint would tell anyone which accounts can be
 * recovered and where the code goes.
 */
function startRecoveryRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);

    const account = typeof body.username === 'string' ? store.stmt.accountByUsername.get(body.username) : null;
    const email = account ? store.stmt.emailForUser.get(account.user_id) : null;
    if (account && email && email.verified === 1) {
      const code = issueCode(store, account.user_id, 'recover', email.email);
      if (code) {
        await mailer.sendMail({
          to: email.email,
          subject: 'HyperChat account recovery',
          text: `Your HyperChat recovery code is ${code}.\nIt expires in 10 minutes.\nIf you didn't try to recover "${account.username}", ignore this email — nobody can get in without the code.`,
        });
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

    const result = checkCode(store, account.user_id, 'recover', body.code);
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
    const ticket = ticketUser(store, req);
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
 * Recovery WITHOUT the backup password: the account keeps its username but
 * gets brand-new keys. Old history can't come back (it was encrypted to the
 * old keys), and every contact sees "security keys changed".
 */
function rebindRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);

    req.headers['x-recovery-ticket'] = body.ticket;
    const ticket = ticketUser(store, req);
    if (!ticket) return sendError(res, 401, 'invalidTicket', 'Recovery session expired. Start again.');

    const validationError = validateBundleUpload(body.bundle);
    if (validationError) return sendError(res, 400, 'badRequest', validationError);

    const account = store.stmt.accountById.get(ticket.userId);
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
      // The old backup is encrypted to the old identity: useless now.
      store.stmt.deleteBackup.run(account.user_id);
      store.stmt.deleteTicket.run(ticket.hash);
    });

    const email = store.stmt.emailForUser.get(account.user_id);
    if (email) {
      await mailer.sendMail({
        to: email.email,
        subject: 'HyperChat account recovered on a new device',
        text: `"${account.username}" was recovered on a new device with new security keys.\nIf this wasn't you, contact support immediately.`,
      });
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
  // exported for tests
  _internal: { checkCode, issueCode, codeHash, normalizeEmail },
};
