'use strict';

const crypto = require('node:crypto');
const { sendJson, sendError, sendNoContent, nowIso, SECURITY_HEADERS } = require('../json');
const { readBody } = require('../router');
const { requireAuth, issueToken } = require('../auth');
const { rateLimit, clientIp } = require('../rateLimit');
const { validateBundleUpload } = require('../validate');
const { consumeChallenge } = require('../challenge');
const { serverSecret } = require('../secret');
const mailer = require('../mailer');

/**
 * Account recovery: a verified recovery email, an optional encrypted backup on
 * the server, and two ways back in on a new device.
 *
 * FIX (S2) — recovery with NEW keys is no longer instant while the account is
 * in use. A 6-digit code from the email used to be enough to replace the
 * identity keys and get a session immediately: whoever controls the mailbox
 * controlled the account. Now, if any device used the account in the last
 * `RECOVERY_ACTIVE_DAYS` (default 14), the first `/recovery/rebind` only starts
 * a waiting period of `RECOVERY_HOLD_HOURS` (default 24) and alerts the signed-in
 * device (live notice, ntfy, Apple push) and the email. The signed-in device can
 * cancel it (`POST /recovery/cancel`). After the wait, recovering again (new code)
 * completes. A lost phone that nobody uses no longer counts as "in use" after
 * `RECOVERY_ACTIVE_DAYS`. Set `RECOVERY_HOLD_HOURS=0` to turn the wait off.
 *
 * Restoring from a backup (old keys + password) is unaffected.
 */
const CODE_TTL_MS = 10 * 60 * 1000;
const CODE_MAX_ATTEMPTS = 5;
const CODE_RESEND_COOLDOWN_MS = 60 * 1000;
const TICKET_TTL_MS = 15 * 60 * 1000;
const MAX_BACKUP_BYTES = 50 * 1024 * 1024;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const DAY_MS = 24 * 60 * 60 * 1000;

const holdHours = () => {
  const v = Number(process.env.RECOVERY_HOLD_HOURS);
  return Number.isFinite(v) && v >= 0 ? v : 24;
};
const activeDays = () => Number(process.env.RECOVERY_ACTIVE_DAYS) || 14;

const sha256 = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
const ipTag = (ip) => crypto.createHmac('sha256', serverSecret()).update(`ip:${ip}`).digest('hex').slice(0, 32);

function assertConfigured() {
  serverSecret();
}

const codeHash = (userId, purpose, code) =>
  crypto.createHmac('sha256', serverSecret()).update(`${userId}:${purpose}:${code}`).digest('hex');
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
 * Issues a code. Returns `{ code }` or `{ error }`.
 *
 * FIX (S11): limits are per account AND per (account, IP), so someone else
 * requesting codes for your account from their address can't use up your
 * allowance. A still-valid **recovery** code is never replaced by a new request:
 * a stranger hammering "send code" used to invalidate the code you were typing.
 */
function issueCode(store, limiters, userId, purpose, email, ip) {
  const existing = store.stmt.codeFor.get(userId, purpose);
  if (existing) {
    const age = Date.now() - new Date(existing.created_at).getTime();
    if (age < CODE_RESEND_COOLDOWN_MS) return { error: 'cooldown' };
    if (purpose === 'recover' && new Date(existing.expires_at).getTime() > Date.now()) {
      return { error: 'stillValid' };
    }
  }
  if (!limiters.codesPerAccountAndIp.take(`${userId}:${purpose}:${ip}`)) return { error: 'tooMany' };
  if (!limiters.codesPerAccount.take(`${userId}:${purpose}`)) return { error: 'tooMany' };

  const code = newCode();
  const now = new Date();
  store.stmt.upsertCode.run(
    userId, purpose, codeHash(userId, purpose, code), email,
    now.toISOString(), new Date(now.getTime() + CODE_TTL_MS).toISOString(), ipTag(ip),
  );
  return { code };
}

/**
 * Checks a code.
 *
 * FIX (S11): a stranger's wrong guesses no longer burn your code. Before, five
 * wrong guesses from anywhere deleted it — anyone could lock you out of recovery
 * indefinitely. Now:
 *   - from the address that requested the code: up to 5 tries per code, as before;
 *   - from any other address: 10 tries per address per hour, and **all** other
 *     addresses together get 50 tries per account per hour. The code survives.
 * Brute force stays hopeless: 50 guesses an hour against 1 000 000 values and a
 * 10-minute code lifetime.
 */
function checkCode(store, limiters, userId, purpose, code, ip) {
  if (!limiters.codeChecksPerIp.take(`${userId}:${purpose}:${ip}`)) return 'tooManyAttempts';

  const row = store.stmt.codeFor.get(userId, purpose);
  if (!row) return 'noCode';
  if (new Date(row.expires_at).getTime() < Date.now()) {
    store.stmt.deleteCode.run(userId, purpose);
    return 'expired';
  }

  const fromRequester = row.requester && row.requester === ipTag(ip);
  if (fromRequester) {
    if (row.attempts >= CODE_MAX_ATTEMPTS) {
      store.stmt.deleteCode.run(userId, purpose);
      return 'tooManyAttempts';
    }
    store.stmt.bumpCodeAttempts.run(userId, purpose);
  } else if (!limiters.codeChecks.take(`${userId}:${purpose}`)) {
    return 'tooManyAttempts';
  }

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

/**
 * FIX (S10): destructive account changes need the device key, not just a token.
 * Shared by set-email, remove-email and delete-backup. Skipped only while
 * `ALLOW_UNSIGNED_EMAIL_CHANGE=1` (app roll-out).
 */
function requireProof(store, req, res, body) {
  if (process.env.ALLOW_UNSIGNED_EMAIL_CHANGE === '1') return true;
  if (typeof body.nonce !== 'string' || typeof body.signature !== 'string') {
    sendError(res, 401, 'proofRequired', 'Confirm this change with this device\'s key. Update the app and try again.');
    return false;
  }
  const account = store.stmt.accountById.get(req.userId);
  const proof = consumeChallenge(store, account, body.nonce, body.signature);
  if (!proof.ok) {
    sendError(res, proof.code === 'badRequest' ? 400 : 401, proof.code, proof.message);
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Signed in: recovery email
// ---------------------------------------------------------------------------

function getEmailRoute(store) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    const row = store.stmt.emailForUser.get(req.userId);
    const pending = store.stmt.codeFor.get(req.userId, 'verify');
    const backup = store.stmt.backupInfoForUser.get(req.userId);
    const hold = store.stmt.holdFor.get(req.userId);
    sendJson(res, 200, {
      email: row ? row.email : null,
      verified: row ? row.verified === 1 : false,
      pendingEmail: pending ? pending.email : null,
      backup: backup ? { sizeBytes: backup.size_bytes, updatedAt: backup.updated_at } : null,
      mailConfigured: mailer.isConfigured(),
      // S2: lets the signed-in app show "someone is trying to recover this account".
      recoveryPending: hold && hold.cancelled === 0 ? { availableAt: hold.available_at } : null,
    });
  };
}

function setEmailRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    const email = normalizeEmail(body.email);
    if (!email) return sendError(res, 400, 'badRequest', 'That email address is not valid.');
    if (!requireProof(store, req, res, body)) return;

    if (!limiters.emailPerAddress.take(email)) {
      return sendError(res, 429, 'rateLimited', 'Too many codes were sent to that address. Try again later.');
    }
    const issued = issueCode(store, limiters, req.userId, 'verify', email, clientIp(req));
    if (issued.error === 'cooldown') return sendError(res, 429, 'rateLimited', 'Wait a minute before requesting another code.');
    if (issued.error) return sendError(res, 429, 'rateLimited', 'Too many codes requested. Try again later.');

    const account = store.stmt.accountById.get(req.userId);
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

function verifyEmailRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    const result = checkCode(store, limiters, req.userId, 'verify', body.code, clientIp(req));
    if (typeof result === 'string') return sendError(res, 400, result, codeErrorMessage[result]);
    store.stmt.upsertVerifiedEmail.run(req.userId, result.email, nowIso());
    sendJson(res, 200, { email: result.email, verified: true });
  };
}

/** POST /account/email/remove { nonce, signature } -> 204  (S10: needs the device key) */
function removeEmailRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (limiters && !rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    if (!requireProof(store, req, res, body)) return;
    const previous = store.stmt.emailForUser.get(req.userId);
    store.transaction(() => {
      store.stmt.deleteEmail.run(req.userId);
      store.stmt.deleteCode.run(req.userId, 'verify');
      store.stmt.deleteBackup.run(req.userId);
    });
    if (previous && previous.verified === 1) {
      mailer.sendMail({
        to: previous.email,
        subject: 'SecureHyperChat recovery email removed',
        text: 'The recovery email and server backup were removed from your SecureHyperChat account. If that wasn\'t you, check your phone.',
      }).catch(() => {});
    }
    sendNoContent(res);
  };
}

// ---------------------------------------------------------------------------
// Signed in: encrypted backup
// ---------------------------------------------------------------------------

function uploadBackupRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.media, req, res)) return;
    const email = store.stmt.emailForUser.get(req.userId);
    if (!email || email.verified !== 1) return sendError(res, 409, 'emailRequired', 'Add and verify a recovery email first.');
    let data;
    try {
      data = await readBody(req, { raw: true, maxBytes: MAX_BACKUP_BYTES });
    } catch (err) {
      if (err.statusCode === 413) return sendError(res, 413, 'payloadTooLarge', 'Backup is larger than 50 MB.');
      throw err;
    }
    if (data.length < 64 || data.subarray(0, 4).toString('latin1') !== 'HCBK') {
      return sendError(res, 400, 'badRequest', 'Not a SecureHyperChat backup.');
    }
    store.stmt.upsertBackup.run(req.userId, data, data.length, nowIso());
    sendNoContent(res);
  };
}

/** POST /backup/delete { nonce, signature } -> 204  (S10) */
function deleteBackupRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (limiters && !rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    if (!requireProof(store, req, res, body)) return;
    store.stmt.deleteBackup.run(req.userId);
    sendNoContent(res);
  };
}

// ---------------------------------------------------------------------------
// Signed in: cancel a recovery attempt (S2)
// ---------------------------------------------------------------------------

/** POST /recovery/cancel -> 204. Any signed-in session of the account may cancel. */
function cancelRecoveryRoute(store, limiters) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.auth, req, res)) return;
    store.transaction(() => {
      store.stmt.cancelHold.run(req.userId);
      store.stmt.deleteTicketsForUser.run(req.userId);
      store.stmt.deleteCode.run(req.userId, 'recover');
    });
    sendNoContent(res);
  };
}

// ---------------------------------------------------------------------------
// Signed out: recovery on a new device
// ---------------------------------------------------------------------------

function startRecoveryRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.recovery, req, res)) return;
    const body = await readBody(req);
    const account = typeof body.username === 'string' && body.username.length <= 64
      ? store.stmt.accountByUsername.get(body.username) : null;
    const email = account ? store.stmt.emailForUser.get(account.user_id) : null;

    if (account && email && email.verified === 1) {
      const issued = issueCode(store, limiters, account.user_id, 'recover', email.email, clientIp(req));
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

function verifyRecoveryRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.recovery, req, res)) return;
    const body = await readBody(req);
    const account = typeof body.username === 'string' && body.username.length <= 64
      ? store.stmt.accountByUsername.get(body.username) : null;
    if (!account) return sendError(res, 400, 'wrongCode', codeErrorMessage.wrongCode);

    const result = checkCode(store, limiters, account.user_id, 'recover', body.code, clientIp(req));
    if (typeof result === 'string') return sendError(res, 400, result, codeErrorMessage[result]);

    store.stmt.deleteExpiredTickets.run(nowIso());
    const ticket = crypto.randomBytes(32).toString('base64url');
    store.stmt.insertTicket.run(sha256(ticket), account.user_id, new Date(Date.now() + TICKET_TTL_MS).toISOString());
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

function downloadBackupRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.recovery, req, res)) return;
    const ticket = ticketUser(store, req.headers['x-recovery-ticket']);
    if (!ticket) return sendError(res, 401, 'invalidTicket', 'Recovery session expired. Start again.');
    const backup = store.stmt.backupForUser.get(ticket.userId);
    if (!backup) return sendError(res, 404, 'noBackup', 'There is no backup on the server.');
    res.writeHead(200, {
      ...SECURITY_HEADERS,
      'Content-Type': 'application/octet-stream',
      'Content-Length': backup.size_bytes,
    });
    res.end(Buffer.from(backup.data));
  };
}

/**
 * POST /recovery/rebind { ticket, bundle } -> AuthToken | 423 recoveryPending
 * @param deps `{ presence, ntfy, apns }`
 */
function rebindRoute(store, limiters, deps = {}) {
  return async (req, res) => {
    if (!rateLimit(limiters.recovery, req, res)) return;
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

    // --- S2: waiting period while another device is using the account -------
    const hours = holdHours();
    if (hours > 0) {
      const now = Date.now();
      const hold = store.stmt.holdFor.get(account.user_id);
      const holdReady = hold && hold.cancelled === 0 && new Date(hold.available_at).getTime() <= now;
      if (!holdReady) {
        const activeSince = new Date(now - activeDays() * DAY_MS).toISOString();
        const inUse = store.stmt.recentSessionCount.get(account.user_id, new Date(now).toISOString(), activeSince).n > 0;
        if (inUse) {
          const pendingHold = hold && hold.cancelled === 0 ? hold : null;
          const availableAt = pendingHold ? pendingHold.available_at : new Date(now + hours * 3_600_000).toISOString();
          if (!pendingHold) {
            store.stmt.insertHold.run(account.user_id, new Date(now).toISOString(), availableAt);
            alertSignedInDevice(store, deps, account, availableAt);
          }
          store.stmt.deleteTicket.run(ticket.hash);
          const when = new Date(availableAt).toUTCString();
          return sendError(res, 423, 'recoveryPending',
            `This account is signed in on another device. For your protection, recovering it with new keys is possible after ${when}. Start recovery again then. If you still have the other device, it can cancel this.`,
            { availableAt });
        }
      }
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
      store.stmt.deletePendingForRecipient.run(account.user_id);
      store.stmt.deleteSessionsForUser.run(account.user_id);
      store.stmt.deleteAllDeviceTokensForUser.run(account.user_id);
      deps.ntfy?.removeTopic(account.user_id);
      store.stmt.deleteBackup.run(account.user_id);
      store.stmt.deleteTicketsForUser.run(account.user_id);
      store.stmt.deleteHold.run(account.user_id);
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

/** Tells every channel we have that someone started recovering the account. */
function alertSignedInDevice(store, deps, account, availableAt) {
  const text = `Someone is recovering "${account.username}" on another device. If it isn't you, open SecureHyperChat → Settings → Account recovery and cancel it before ${new Date(availableAt).toUTCString()}.`;
  deps.presence?.notify(account.user_id, { kind: 'recoveryPending', availableAt });
  deps.ntfy?.notifyUser(account.user_id, text).catch(() => {});
  if (deps.apns) {
    for (const { token, environment } of store.stmt.deviceTokensForUser.all(account.user_id)) {
      deps.apns.send(token, environment, {
        aps: { alert: { title: 'SecureHyperChat', body: 'Someone is trying to recover your account.' }, sound: 'default' },
      }).catch(() => {});
    }
  }
  const email = store.stmt.emailForUser.get(account.user_id);
  if (email) {
    mailer.sendMail({ to: email.email, subject: 'SecureHyperChat recovery started', text }).catch(() => {});
  }
}

module.exports = {
  getEmailRoute,
  setEmailRoute,
  verifyEmailRoute,
  removeEmailRoute,
  uploadBackupRoute,
  deleteBackupRoute,
  cancelRecoveryRoute,
  startRecoveryRoute,
  verifyRecoveryRoute,
  downloadBackupRoute,
  rebindRoute,
  assertConfigured,
  _internal: { checkCode, issueCode, codeHash, normalizeEmail },
};
