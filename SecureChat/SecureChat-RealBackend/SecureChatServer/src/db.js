'use strict';

const { DatabaseSync } = require('node:sqlite');
const fs = require('node:fs');
const path = require('node:path');

/**
 * Schema and prepared-statement layer.
 *
 * Deliberately zero third-party dependencies: `node:sqlite` (stable since
 * Node 22.5, used here on Node 24) gives a real, durable, file-backed
 * database with transactions and a `RETURNING` clause — enough to replace
 * `MockBackendStore`'s in-memory Swift dictionaries without adding a
 * Postgres/Redis operational dependency to a scaffold.
 *
 * Swapping to Postgres later only means rewriting this one file behind the
 * same function signatures (`registerAccount`, `popOneTimePreKey`, etc.);
 * nothing in server.js or the route handlers is SQLite-specific.
 */
class Store {
  constructor(filePath) {
    const isMemory = filePath === ':memory:';
    if (!isMemory) {
      fs.mkdirSync(path.dirname(filePath), { recursive: true });
    }
    this.db = new DatabaseSync(filePath);

    // WAL gives readers/writers concurrent access without blocking — matters
    // once the HTTP handlers and the WebSocket push logic touch the database
    // from the same process concurrently. No-op (and harmless) on :memory:.
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

      -- The durable per-recipient queue. A row here is exactly one envelope
      -- this recipient has not yet acknowledged. Rows are deleted on ack, so
      -- this table is never a permanent message archive — the server relays,
      -- it does not retain. That is a deliberate divergence from
      -- MockBackendStore, whose in-memory 'envelopesByConversation' archive
      -- kept every envelope forever; a real server holding indefinite
      -- ciphertext history is a bigger blast radius for no product benefit,
      -- since clients already persist their own decrypted history locally.
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
      CREATE INDEX IF NOT EXISTS idx_pending_recipient_seq
        ON pending_envelopes(recipient_id, sequence);
      CREATE INDEX IF NOT EXISTS idx_pending_recipient_conversation
        ON pending_envelopes(recipient_id, conversation_id);

      CREATE TABLE IF NOT EXISTS media_blobs (
        media_id   TEXT PRIMARY KEY,
        data       BLOB NOT NULL,
        size_bytes INTEGER NOT NULL,
        created_at TEXT NOT NULL
      );
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
        UPDATE accounts
        SET signed_prekey_id = ?, signed_prekey = ?, signed_prekey_signature = ?
        WHERE user_id = ?
      `),

      insertOneTimePreKey: db.prepare(`
        INSERT OR IGNORE INTO one_time_prekeys (user_id, prekey_id, public_key)
        VALUES (?, ?, ?)
      `),
      // Pop = delete-and-return the lowest-id unconsumed prekey, atomically.
      // This is what makes it genuinely one-time: two concurrent bundle
      // fetches for the same user cannot both receive the same prekey,
      // because SQLite serializes writers and each DELETE only ever matches
      // one row.
      popOneTimePreKey: db.prepare(`
        DELETE FROM one_time_prekeys
        WHERE user_id = ? AND prekey_id = (
          SELECT MIN(prekey_id) FROM one_time_prekeys WHERE user_id = ?
        )
        RETURNING prekey_id, public_key
      `),
      countOneTimePreKeys: db.prepare(`
        SELECT COUNT(*) AS n FROM one_time_prekeys WHERE user_id = ?
      `),

      insertSession: db.prepare(`
        INSERT INTO sessions (token_hash, user_id, created_at, expires_at)
        VALUES (?, ?, ?, ?)
      `),
      sessionByHash: db.prepare(`SELECT * FROM sessions WHERE token_hash = ?`),
      deleteExpiredSessions: db.prepare(`DELETE FROM sessions WHERE expires_at < ?`),
      deleteSessionsForUser: db.prepare(`DELETE FROM sessions WHERE user_id = ?`),

      insertPendingEnvelope: db.prepare(`
        INSERT OR IGNORE INTO pending_envelopes
          (envelope_id, conversation_id, sender_id, recipient_id, kind,
           handshake_json, ratchet_message, content_type, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING sequence
      `),
      pendingSince: db.prepare(`
        SELECT * FROM pending_envelopes
        WHERE recipient_id = ? AND sequence > ?
        ORDER BY sequence ASC
        LIMIT ?
      `),
      pendingByConversation: db.prepare(`
        SELECT * FROM pending_envelopes
        WHERE recipient_id = ? AND conversation_id = ?
        ORDER BY sequence ASC
      `),
      ackEnvelope: db.prepare(`
        DELETE FROM pending_envelopes WHERE recipient_id = ? AND envelope_id = ?
      `),
      pendingCountForUser: db.prepare(`
        SELECT COUNT(*) AS n FROM pending_envelopes WHERE recipient_id = ?
      `),

      insertMedia: db.prepare(`
        INSERT INTO media_blobs (media_id, data, size_bytes, created_at) VALUES (?, ?, ?, ?)
      `),
      mediaById: db.prepare(`SELECT * FROM media_blobs WHERE media_id = ?`),
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
