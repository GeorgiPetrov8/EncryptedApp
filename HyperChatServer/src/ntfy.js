'use strict';

/**
 * Opt-in notifications through ntfy (https://ntfy.sh), for builds without
 * Apple push (free developer accounts / SideStore).
 *
 * The user installs the ntfy app, subscribes to a random topic HyperChat
 * generated for them, and the server posts a generic "New message" to that
 * topic when something arrives while HyperChat is closed. The message text
 * is never sent — ntfy only learns *that* something arrived.
 *
 * Self-contained: creates its own table, so db.js doesn't change.
 *
 * Environment (optional):
 *   NTFY_BASE_URL  default https://ntfy.sh — set to your own ntfy server
 *   NTFY_TOKEN     access token, if that server requires one
 */

/** ntfy's own topic rule, plus a minimum length so it can't be guessed. */
const TOPIC_RE = /^[A-Za-z0-9_-]{20,64}$/;

/** At most one notification per conversation per this interval. */
const THROTTLE_MS = 30 * 1000;

const ALERTS = {
  text: { title: 'HyperChat', body: 'New message', tags: 'speech_balloon' },
  image: { title: 'HyperChat', body: 'New photo', tags: 'camera' },
  video: { title: 'HyperChat', body: 'New video', tags: 'movie_camera' },
  file: { title: 'HyperChat', body: 'New attachment', tags: 'paperclip' },
  invite: { title: 'HyperChat', body: 'New chat invitation', tags: 'wave' },
  call: { title: 'HyperChat', body: 'Incoming call', tags: 'telephone_receiver', priority: '5' },
  // Background bookkeeping — never notified.
  receipt: null,
  profile: null,
  notePad: null,
  edit: null,
};

class Ntfy {
  constructor(store, { baseUrl = process.env.NTFY_BASE_URL || 'https://ntfy.sh', token = process.env.NTFY_TOKEN, fetchImpl = fetch } = {}) {
    this.store = store;
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.token = token;
    this.fetch = fetchImpl;
    this.lastSent = new Map(); // `${userId}:${conversationId}` -> ms
    store.db.exec(`
      CREATE TABLE IF NOT EXISTS ntfy_topics (
        user_id    TEXT PRIMARY KEY,
        topic      TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES accounts(user_id) ON DELETE CASCADE
      );
    `);
    this.stmt = {
      upsert: store.db.prepare(`
        INSERT INTO ntfy_topics (user_id, topic, updated_at) VALUES (?, ?, ?)
        ON CONFLICT(user_id) DO UPDATE SET topic = excluded.topic, updated_at = excluded.updated_at
      `),
      get: store.db.prepare(`SELECT topic FROM ntfy_topics WHERE user_id = ?`),
      remove: store.db.prepare(`DELETE FROM ntfy_topics WHERE user_id = ?`),
    };
  }

  static isValidTopic(topic) {
    return typeof topic === 'string' && TOPIC_RE.test(topic);
  }

  setTopic(userId, topic) {
    this.stmt.upsert.run(userId, topic, new Date().toISOString());
  }

  removeTopic(userId) {
    this.stmt.remove.run(userId);
  }

  topicFor(userId) {
    return this.stmt.get.get(userId)?.topic ?? null;
  }

  /** POSTs one notification. Never throws. */
  async publish(topic, { title, body, tags, priority }) {
    const headers = {
      Title: title,
      Tags: tags,
      // Tapping the notification opens HyperChat (needs the `hyperchat` URL
      // scheme registered in the app; otherwise it opens ntfy).
      Click: 'hyperchat://',
    };
    if (priority) headers.Priority = priority;
    if (this.token) headers.Authorization = `Bearer ${this.token}`;
    try {
      const res = await this.fetch(`${this.baseUrl}/${encodeURIComponent(topic)}`, {
        method: 'POST',
        headers,
        body,
        signal: AbortSignal.timeout(10_000),
      });
      if (!res.ok) console.error(`[ntfy] publish failed: HTTP ${res.status}`);
      return res.ok;
    } catch (err) {
      console.error('[ntfy] publish failed:', err.message);
      return false;
    }
  }

  /**
   * Called after an envelope is queued. Notifies only if the recipient
   * opted in, isn't currently connected, the content type is user-visible,
   * and this conversation wasn't notified moments ago.
   */
  async notifyForEnvelope(envelope, presence) {
    const alert = ALERTS[envelope.contentType];
    if (!alert) return false;
    if (presence && presence.isOnline(envelope.recipientId)) return false;

    const topic = this.topicFor(envelope.recipientId);
    if (!topic) return false;

    // Calls always go through; everything else is throttled per conversation,
    // so a burst of 20 messages is one notification, not 20.
    const key = `${envelope.recipientId}:${envelope.conversationId}`;
    const now = Date.now();
    if (envelope.contentType !== 'call' && now - (this.lastSent.get(key) ?? 0) < THROTTLE_MS) return false;
    this.lastSent.set(key, now);
    if (this.lastSent.size > 10_000) this.lastSent.clear();

    return this.publish(topic, alert);
  }
}

module.exports = { Ntfy, ALERTS, THROTTLE_MS };
