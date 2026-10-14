'use strict';

const { isValidUserId } = require('./validate');

/**
 * Live connections + presence.
 *
 * Presence is disclosed only between *mutual* contacts (each side has listed
 * the other in its `contacts` frame), and only while the user is visible (app in
 * the foreground AND "show when I'm online" enabled). Offline is never reported
 * as a timestamp — the client just stops showing "online".
 */
const MAX_CONTACTS = 500;

class Presence {
  constructor() {
    this.connections = new Map(); // userId -> WebSocketConnection
    this.contacts = new Map();    // userId -> Set<userId>
    this.visible = new Map();     // userId -> boolean
  }

  register(userId, connection) {
    const existing = this.connections.get(userId);
    // Record the new connection BEFORE closing the old one: the old one's close
    // handler asks "am I still current?", and closing first made it answer yes —
    // a spurious "offline" broadcast on every reconnect.
    this.connections.set(userId, connection);
    if (existing && existing !== connection) {
      existing.close(4000, 'replaced by a newer connection');
    }

    connection.on('close', () => {
      // Only the *current* connection going away means the user went offline.
      if (this.connections.get(userId) !== connection) return;
      this.connections.delete(userId);
      this.broadcast(userId);
      // Dropped only after the broadcast, which still needs the contact list.
      // Without this the two maps grew by one entry per user, forever. The
      // client re-sends both on reconnect.
      this.forget(userId);
    });
  }

  /** Delivers an envelope over the live socket, if any. */
  push(userId, envelopeJson) {
    const conn = this.connections.get(userId);
    if (!conn) return false;
    conn.sendText(JSON.stringify({ type: 'envelope', envelope: envelopeJson }));
    return true;
  }

  isOnline(userId) { return this.connections.has(userId); }
  count() { return this.connections.size; }

  /** Closes one user's socket (account deleted / recovered / logged out). */
  disconnect(userId, code = 1000, reason = '') {
    this.connections.get(userId)?.close(code, reason);
  }

  closeAll(code = 1001, reason = 'server shutting down') {
    for (const conn of [...this.connections.values()]) conn.close(code, reason);
  }

  // --- presence -----------------------------------------------------------

  /** Client tells us who its accepted contacts are. Replies with a snapshot. */
  setContacts(userId, contactIds) {
    const ids = Array.isArray(contactIds)
      ? contactIds.filter((id) => isValidUserId(id) && id !== userId).slice(0, MAX_CONTACTS)
      : [];
    const next = new Set(ids);
    const previous = this.contacts.get(userId);
    const changed = !previous || previous.size !== next.size || [...next].some((id) => !previous.has(id));

    this.contacts.set(userId, next);
    // The snapshot is sent after contacts are known: sent on connect, before this
    // frame, it would always be empty.
    this.sendSnapshot(userId);
    // Re-announcing to every contact on each frame let a client amplify a single
    // message into many; only announce when the list actually changed.
    if (changed) this.broadcast(userId);
  }

  setVisible(userId, isVisible) {
    const next = isVisible !== false;
    const changed = this.visible.get(userId) !== next;
    this.visible.set(userId, next);
    if (changed) this.broadcast(userId);
  }

  forget(userId) {
    this.contacts.delete(userId);
    this.visible.delete(userId);
  }

  isMutual(a, b) {
    return (this.contacts.get(a)?.has(b) ?? false) && (this.contacts.get(b)?.has(a) ?? false);
  }

  isVisiblyOnline(userId) {
    return this.connections.has(userId) && this.visible.get(userId) !== false;
  }

  onlineContactsOf(userId) {
    const mine = this.contacts.get(userId) ?? new Set();
    return [...mine].filter((id) => this.isMutual(userId, id) && this.isVisiblyOnline(id));
  }

  sendSnapshot(userId) {
    const conn = this.connections.get(userId);
    if (!conn) return;
    conn.sendText(JSON.stringify({
      type: 'presence', kind: 'snapshot', userIds: this.onlineContactsOf(userId),
    }));
  }

  /** Tells every mutual, connected contact of `userId` its current state. */
  broadcast(userId) {
    const online = this.isVisiblyOnline(userId);
    const mine = this.contacts.get(userId) ?? new Set();
    for (const otherId of mine) {
      if (!this.isMutual(userId, otherId)) continue;
      const conn = this.connections.get(otherId);
      if (!conn) continue;
      conn.sendText(JSON.stringify({
        type: 'presence', kind: online ? 'online' : 'offline', userIds: [userId],
      }));
    }
  }
}

module.exports = { Presence };
