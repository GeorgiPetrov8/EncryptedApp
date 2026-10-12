'use strict';

/**
 * Live connections + presence.
 *
 * Presence is disclosed only between *mutual* contacts (each side has listed the
 * other in its `contacts` frame), and only while the user is visible
 * (app in foreground AND "show when I'm online" enabled). Offline is never
 * reported as a timestamp — the client just stops showing "online".
 */
class Presence {
  constructor() {
    this.connections = new Map(); // userId -> WebSocketConnection
    this.contacts = new Map();    // userId -> Set<userId>
    this.visible = new Map();     // userId -> boolean
  }

  register(userId, connection) {
    const existing = this.connections.get(userId);
    // Record the new connection *before* closing the old one: the old one's
    // close handler checks "am I still current?", and closing first made it
    // answer yes — broadcasting a spurious "offline" on every reconnect.
    this.connections.set(userId, connection);
    if (existing && existing !== connection) {
      existing.close(4000, 'replaced by a newer connection');
    }
    connection.on('close', () => {
      // Only the *current* connection going away means the user went offline;
      // a replaced connection closing must not broadcast "offline".
      if (this.connections.get(userId) === connection) {
        this.connections.delete(userId);
        this.broadcast(userId);
      }
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

  // --- presence -----------------------------------------------------------

  /** Client tells us who its accepted contacts are. Replies with a snapshot. */
  setContacts(userId, contactIds) {
    const ids = Array.isArray(contactIds)
      ? contactIds.filter((id) => typeof id === 'string' && id !== userId).slice(0, 5000)
      : [];
    this.contacts.set(userId, new Set(ids));
    // The snapshot must be sent *after* contacts are known — sending it on
    // connect, before this frame arrives, always yields an empty set.
    this.sendSnapshot(userId);
    // Newly-mutual contacts need to learn our current state too.
    this.broadcast(userId);
  }

  setVisible(userId, isVisible) {
    this.visible.set(userId, isVisible !== false);
    this.broadcast(userId);
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
