'use strict';

/**
 * Opt-in notifications through ntfy (https://ntfy.sh), for builds without
 * Apple push. The message text is never sent — ntfy only learns *that*
 * something arrived, and of what kind.
 *
 * The `ntfy_topics` table is created by db.js (schema v2; R15).
 *
 * Environment (optional):
 *   NTFY_BASE_URL  default https://ntfy.sh — set to your own ntfy server to keep
 *                  even the "something arrived" signal off a third party (S29)
 *   NTFY_TOKEN     access token, if that server requires one
 *   NTFY_GENERIC   "1" = every alert says just "New activity" (hides the type)
 */
const TOPIC_RE = /^[A-Za-z0-9_-]{20,64}$/;
const THROTTLE_MS = 30 * 1000;

const ALERTS = {
  text: { title: 'SecureHyperChat', body: 'New message', tags: 'speech_balloon' },
  image: { title: 'SecureHyperChat', body: 'New photo', tags: 'camera' },
  video: { title: 'SecureHyperChat', body: 'New video', tags: 'movie_camera' },
  file: { title: 'SecureHyperChat', body: 'New attachment', tags: 'paperclip' },
  invite: { title: 'SecureHyperChat', body: 'New chat invitation', tags: 'wave' },
  call: { title: 'SecureHyperChat', body: 'Incoming call', tags: 'telephone_receiver', priority: '5' },
  receipt: null,
  profile: null,
  notePad: null,
  edit: null,
  reaction: null,
};

const GENERIC = { title: 'SecureHyperChat', body: 'New activity', tags: 'bell' };

class Ntfy {
  constructor(store, { baseUrl = process.env.NTFY_BASE_URL || 'https://ntfy.sh', token = process.env.NTFY_TOKEN, fetchImpl = fetch } = {}) {
    this.store = store;
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.token = token;
    this.fetch = fetchImpl;
    this.lastSent = new Map();
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

  setTopic(userId, topic) { this.stmt.upsert.run(userId, topic, new Date().toISOString()); }
  removeTopic(userId) { this.stmt.remove.run(userId); }
  topicFor(userId) { return this.stmt.get.get(userId)?.topic ?? null; }

  async publish(topic, { title, body, tags, priority }) {
    const headers = { Title: title, Tags: tags, Click: 'hyperchat://' };
    if (priority) headers.Priority = priority;
    if (this.token) headers.Authorization = `Bearer ${this.token}`;
    try {
      const res = await this.fetch(`${this.baseUrl}/${encodeURIComponent(topic)}`, {
        method: 'POST', headers, body, signal: AbortSignal.timeout(10_000),
      });
      if (!res.ok) console.error(`[ntfy] publish failed: HTTP ${res.status}`);
      return res.ok;
    } catch (err) {
      console.error('[ntfy] publish failed:', err.message);
      return false;
    }
  }

  async notifyForEnvelope(envelope, presence) {
    const alert = ALERTS[envelope.contentType];
    if (!alert) return false;
    if (presence && presence.isOnline(envelope.recipientId)) return false;
    const topic = this.topicFor(envelope.recipientId);
    if (!topic) return false;

    const key = `${envelope.recipientId}:${envelope.conversationId}`;
    const now = Date.now();
    if (envelope.contentType !== 'call' && now - (this.lastSent.get(key) ?? 0) < THROTTLE_MS) return false;
    this.lastSent.set(key, now);
    if (this.lastSent.size > 10_000) {
      for (const [k, t] of this.lastSent) if (now - t > THROTTLE_MS) this.lastSent.delete(k);
    }
    return this.publish(topic, process.env.NTFY_GENERIC === '1' ? GENERIC : alert);
  }

  /** Free-form system notice to one user (used for recovery alerts). */
  async notifyUser(userId, body) {
    const topic = this.topicFor(userId);
    if (!topic) return false;
    return this.publish(topic, { title: 'SecureHyperChat', body, tags: 'warning', priority: '5' });
  }
}

module.exports = { Ntfy, ALERTS, THROTTLE_MS };
