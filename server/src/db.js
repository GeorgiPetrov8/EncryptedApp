'use strict';

const { DatabaseSync } = require('node:sqlite');
const fs = require('node:fs');
const path = require('node:path');

/**
 * Schema and prepared-statement layer. Zero third-party dependencies.
 *
 * Additions in this version:
 *   retired_usernames — names of deleted accounts, never handed out again
 *                       (otherwise a stranger could re-register "maria" and
 *                       inherit her contacts' trust)
 *   device_tokens     — APNs device tokens for push notifications
 */
class Store {
  constructor(filePath) {
    const isMemory = filePath === ':memory:';
    if (!isMemory) {
      fs.mkdirSync(path.dirname(filePath), { recursive: true });
    }
    this.db = new DatabaseSync(filePath);
    if (!isMemory) {
      this.db.exec('PRAGMA journal_mode = WAL');
      this.db.exec('PRAGMA synchronous = NORMAL');
    }
    this.db.exec('PRAGMA foreign_keys = ON');
    this._migrate();
    this._prepare();
  }

  _migrate() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS accounts (
        user_id                 TEXT PRIMARY KEY,
        username                TEXT NOT NULL UNIQUE COLLATE NOCASE,
        identity_agreement_key  TEXT NOT NULL,
        identity_signing_key    TEXT NOT NULL,
        signed_prekey_id        INTEGER NOT NULL,
        signed_prekey           TEXT NOT NULL,
        signed_prekey_signature TEXT NOT NULL,
        created_at              TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS one_time_prekeys (
        user_id    TEXT NOT NULL,
        prekey_id  INTEGER NOT NULL,
        public_key TEXT NOT NULL,
        PRIMARY KEY (user_id, prekey_id),
        FOREIGN KEY (user_id) REFERENCES accounts(user_id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY,
        user_id    TEXT NOT NULL,
        created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES accounts(user_id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);

      CREATE TABLE IF NOT EXISTS login_challenges (
        nonce_hash TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES accounts(user_id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_login_challenges_user ON login_challenges(user_id);
      CREATE INDEX IF NOT EXISTS idx_login_challenges_expires ON login_challenges(expires_at);

      CREATE TABLE IF NOT EXISTS invites (
        sender_id TEXT NOT NULL,
        recipient_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (sender_id, recipient_id)
      );
      CREATE INDEX IF NOT EXISTS idx_invites_sender_created ON invites(sender_id, created_at);

      -- Durable per-recipient queue. Rows are deleted on ack: the server
      -- relays, it does not retain.
      CREATE TABLE IF NOT EXISTS pending_envelopes (
        sequence         INTEGER PRIMARY KEY AUTOINCREMENT,
        envelope_id      TEXT NOT NULL,
        conversation_id  TEXT NOT NULL,
        sender_id        TEXT NOT NULL,
        recipient_id     TEXT NOT NULL,
        kind             TEXT NOT NULL,
        handshake_json   TEXT,
        ratchet_message  TEXT NOT NULL,
        content_type     TEXT NOT NULL,
        created_at       TEXT NOT NULL,
        UNIQUE (recipient_id, sender_id, envelope_id)
      );
      CREATE INDEX IF NOT EXISTS idx_pending_recipient_seq ON pending_envelopes(recipient_id, sequence);
      CREATE INDEX IF NOT EXISTS idx_pending_recipient_conversation ON pending_envelopes(recipient_id, conversation_id);

      CREATE TABLE IF NOT EXISTS media_blobs (
        media_id   TEXT PRIMARY KEY,
        data       BLOB NOT NULL,
        size_bytes INTEGER NOT NULL,
        created_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_media_blobs_created ON media_blobs(created_at);

      -- ---------------- Account recovery ----------------

      CREATE TABLE IF NOT EXISTS account_emails (
        user_id    TEXT PRIMARY KEY,
        email      TEXT NOT NULL,
        verified   INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES accounts(user_id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS email_codes (
        user_id    TEXT NOT NULL,
        purpose    TEXT NOT NULL,
        code_hash  TEXT NOT NULL,
        email      TEXT NOT NULL,
        attempts   INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY (user_id, purpose),
        FOREIGN KEY (user_id) REFERENCES accounts(user_id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS recovery_tickets (
        ticket_hash TEXT PRIMARY KEY,
        user_id     TEXT NOT NULL,
        expires_at  TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES accounts(user_id) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS backups (
        user_id    TEXT PRIMARY KEY,
        data       BLOB NOT NULL,
        size_bytes INTEGER NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES accounts(user_id) ON DELETE CASCADE
      );

      -- ---------------- Account deletion ----------------

      CREATE TABLE IF NOT EXISTS retired_usernames (
        username   TEXT PRIMARY KEY COLLATE NOCASE,
        retired_at TEXT NOT NULL
      );

      -- ---------------- Push notifications ----------------

      CREATE TABLE IF NOT EXISTS device_tokens (
        token       TEXT PRIMARY KEY,
        user_id     TEXT NOT NULL,
        environment TEXT NOT NULL,           -- 'sandbox' | 'production'
        updated_at  TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES accounts(user_id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_device_tokens_user ON device_tokens(user_id);
    `);
  }

  _prepare() {
    const db = this.db;
    this.stmt = {
      insertAccount: db.prepare(`
        INSERT INTO accounts
          (user_id, username, identity_agreement_key, identity_signing_key,
           signed_prekey_id, signed_prekey, signed_prekey_signature, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      `),
      accountByUsername: db.prepare(`SELECT * FROM accounts WHERE username = ? COLLATE NOCASE`),
      accountById: db.prepare(`SELECT * FROM accounts WHERE user_id = ?`),
      updateSignedPreKey: db.prepare(`
        UPDATE accounts SET signed_prekey_id = ?, signed_prekey = ?, signed_prekey_signature = ?
        WHERE user_id = ?
      `),
      insertOneTimePreKey: db.prepare(`
        INSERT OR IGNORE INTO one_time_prekeys (user_id, prekey_id, public_key) VALUES (?, ?, ?)
      `),
      popOneTimePreKey: db.prepare(`
        DELETE FROM one_time_prekeys
        WHERE user_id = ? AND prekey_id = (SELECT MIN(prekey_id) FROM one_time_prekeys WHERE user_id = ?)
        RETURNING prekey_id, public_key
      `),
      countOneTimePreKeys: db.prepare(`SELECT COUNT(*) AS n FROM one_time_prekeys WHERE user_id = ?`),

      insertSession: db.prepare(`
        INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)
      `),
      sessionByHash: db.prepare(`SELECT * FROM sessions WHERE token_hash = ?`),
      deleteExpiredSessions: db.prepare(`DELETE FROM sessions WHERE expires_at < ?`),
      deleteSessionsForUser: db.prepare(`DELETE FROM sessions WHERE user_id = ?`),

      insertLoginChallenge: db.prepare(`
        INSERT INTO login_challenges (nonce_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)
      `),
      loginChallengeByHash: db.prepare(`SELECT * FROM login_challenges WHERE nonce_hash = ?`),
      deleteLoginChallenge: db.prepare(`DELETE FROM login_challenges WHERE nonce_hash = ?`),
      deleteExpiredLoginChallenges: db.prepare(`DELETE FROM login_challenges WHERE expires_at < ?`),

      countInvitesSince: db.prepare(`
        SELECT COUNT(*) AS n FROM invites WHERE sender_id = ? AND created_at >= ?
      `),
      upsertInvite: db.prepare(`
        INSERT INTO invites (sender_id, recipient_id, created_at) VALUES (?, ?, ?)
        ON CONFLICT(sender_id, recipient_id) DO UPDATE SET created_at = excluded.created_at
      `),

      insertPendingEnvelope: db.prepare(`
        INSERT OR IGNORE INTO pending_envelopes
          (envelope_id, conversation_id, sender_id, recipient_id, kind,
           handshake_json, ratchet_message, content_type, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING sequence
      `),
      pendingSince: db.prepare(`
        SELECT * FROM pending_envelopes WHERE recipient_id = ? AND sequence > ?
        ORDER BY sequence ASC LIMIT ?
      `),
      pendingByConversation: db.prepare(`
        SELECT * FROM pending_envelopes WHERE recipient_id = ? AND conversation_id = ?
        ORDER BY sequence ASC
      `),
      ackEnvelope: db.prepare(`DELETE FROM pending_envelopes WHERE recipient_id = ? AND envelope_id = ?`),
      pendingCountForUser: db.prepare(`SELECT COUNT(*) AS n FROM pending_envelopes WHERE recipient_id = ?`),

      insertMedia: db.prepare(`
        INSERT INTO media_blobs (media_id, data, size_bytes, created_at) VALUES (?, ?, ?, ?)
      `),
      mediaById: db.prepare(`SELECT * FROM media_blobs WHERE media_id = ?`),
      deleteExpiredMedia: db.prepare(`DELETE FROM media_blobs WHERE created_at < ?`),

      // ---------------- Account recovery ----------------

      emailForUser: db.prepare(`SELECT * FROM account_emails WHERE user_id = ?`),
      upsertVerifiedEmail: db.prepare(`
        INSERT INTO account_emails (user_id, email, verified, updated_at) VALUES (?, ?, 1, ?)
        ON CONFLICT(user_id) DO UPDATE SET email = excluded.email, verified = 1, updated_at = excluded.updated_at
      `),
      deleteEmail: db.prepare(`DELETE FROM account_emails WHERE user_id = ?`),

      codeFor: db.prepare(`SELECT * FROM email_codes WHERE user_id = ? AND purpose = ?`),
      upsertCode: db.prepare(`
        INSERT INTO email_codes (user_id, purpose, code_hash, email, attempts, created_at, expires_at)
        VALUES (?, ?, ?, ?, 0, ?, ?)
        ON CONFLICT(user_id, purpose) DO UPDATE SET
          code_hash = excluded.code_hash, email = excluded.email, attempts = 0,
          created_at = excluded.created_at, expires_at = excluded.expires_at
      `),
      bumpCodeAttempts: db.prepare(`
        UPDATE email_codes SET attempts = attempts + 1 WHERE user_id = ? AND purpose = ?
      `),
      deleteCode: db.prepare(`DELETE FROM email_codes WHERE user_id = ? AND purpose = ?`),

      insertTicket: db.prepare(`
        INSERT INTO recovery_tickets (ticket_hash, user_id, expires_at) VALUES (?, ?, ?)
      `),
      ticketByHash: db.prepare(`SELECT * FROM recovery_tickets WHERE ticket_hash = ?`),
      deleteTicket: db.prepare(`DELETE FROM recovery_tickets WHERE ticket_hash = ?`),
      deleteExpiredTickets: db.prepare(`DELETE FROM recovery_tickets WHERE expires_at < ?`),

      upsertBackup: db.prepare(`
        INSERT INTO backups (user_id, data, size_bytes, updated_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(user_id) DO UPDATE SET
          data = excluded.data, size_bytes = excluded.size_bytes, updated_at = excluded.updated_at
      `),
      backupForUser: db.prepare(`SELECT * FROM backups WHERE user_id = ?`),
      backupInfoForUser: db.prepare(`SELECT size_bytes, updated_at FROM backups WHERE user_id = ?`),
      deleteBackup: db.prepare(`DELETE FROM backups WHERE user_id = ?`),

      replaceIdentity: db.prepare(`
        UPDATE accounts SET
          identity_agreement_key = ?, identity_signing_key = ?,
          signed_prekey_id = ?, signed_prekey = ?, signed_prekey_signature = ?
        WHERE user_id = ?
      `),
      deleteOneTimePreKeysForUser: db.prepare(`DELETE FROM one_time_prekeys WHERE user_id = ?`),
      deletePendingForRecipient: db.prepare(`DELETE FROM pending_envelopes WHERE recipient_id = ?`),

      // ---------------- Account deletion ----------------

      isUsernameRetired: db.prepare(`SELECT 1 AS x FROM retired_usernames WHERE username = ? COLLATE NOCASE`),
      retireUsername: db.prepare(`
        INSERT OR IGNORE INTO retired_usernames (username, retired_at) VALUES (?, ?)
      `),
      deletePendingFromSender: db.prepare(`DELETE FROM pending_envelopes WHERE sender_id = ?`),
      deleteInvitesForUser: db.prepare(`DELETE FROM invites WHERE sender_id = ? OR recipient_id = ?`),
      // Cascades: prekeys, sessions, login challenges, email, codes,
      // tickets, backup, device tokens.
      deleteAccountRow: db.prepare(`DELETE FROM accounts WHERE user_id = ?`),

      // ---------------- Push notifications ----------------

      upsertDeviceToken: db.prepare(`
        INSERT INTO device_tokens (token, user_id, environment, updated_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(token) DO UPDATE SET
          user_id = excluded.user_id, environment = excluded.environment, updated_at = excluded.updated_at
      `),
      deviceTokensForUser: db.prepare(`SELECT token, environment FROM device_tokens WHERE user_id = ?`),
      deleteDeviceToken: db.prepare(`DELETE FROM device_tokens WHERE token = ?`),
      deleteDeviceTokenForUser: db.prepare(`DELETE FROM device_tokens WHERE token = ? AND user_id = ?`),
    };
  }

  transaction(fn) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const result = fn();
      this.db.exec('COMMIT');
      return result;
    } catch (err) {
      this.db.exec('ROLLBACK');
      throw err;
    }
  }

  close() {
    this.db.close();
  }
}

module.exports = { Store };
