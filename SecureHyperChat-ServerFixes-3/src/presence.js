'use strict';

const { isValidUserId } = require('./validate');

/**
 * Live connections + presence. Presence is disclosed only between *mutual*
 * contacts, only while the user is visible; offline is never a timestamp.
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
    this.connections.set(userId, connection);
    if (existing && existing !== connection) {
      existing.close(4000, 'replaced by a newer connection');
    }
    connection.on('close', () => {
      if (this.connections.get(userId) !== connection) return;
      this.connections.delete(userId);
      this.broadcast(userId);
      this.forget(userId);
    });
  }

  push(userId, envelopeJson) {
    const conn = this.connections.get(userId);
    if (!conn) return false;
    conn.sendText(JSON.stringify({ type: 'envelope', envelope: envelopeJson }));
    return true;
  }

  /** A server notice the app may show (unknown types are ignored by old apps). */
  notify(userId, payload) {
    const conn = this.connections.get(userId);
    if (!conn) return false;
    conn.sendText(JSON.stringify({ type: 'notice', ...payload }));
    return true;
  }

  isOnline(userId) { return this.connections.has(userId); }
  count() { return this.connections.size; }

  disconnect(userId, code = 1000, reason = '') {
    this.connections.get(userId)?.close(code, reason);
  }

  closeAll(code = 1001, reason = 'server shutting down') {
    for (const conn of [...this.connections.values()]) conn.close(code, reason);
  }

  /**
   * @param {(a: string, b: string) => boolean} [isRelated] optional server-side
   *   check that the two really have a relationship (S15): a contacts list is the
   *   client's claim; it is filtered against the invitations the server saw.
   */
  setContacts(userId, contactIds, isRelated) {
    let ids = Array.isArray(contactIds)
      ? contactIds.filter((id) => isValidUserId(id) && id !== userId).slice(0, MAX_CONTACTS)
      : [];
    if (isRelated) ids = ids.filter((id) => isRelated(userId, id));
    const next = new Set(ids);
    const previous = this.contacts.get(userId);
    const changed = !previous || previous.size !== next.size || [...next].some((id) => !previous.has(id));
    this.contacts.set(userId, next);
    this.sendSnapshot(userId);
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
    conn.sendText(JSON.stringify({ type: 'presence', kind: 'snapshot', userIds: this.onlineContactsOf(userId) }));
  }

  broadcast(userId) {
    const online = this.isVisiblyOnline(userId);
    const mine = this.contacts.get(userId) ?? new Set();
    for (const otherId of mine) {
      if (!this.isMutual(userId, otherId)) continue;
      const conn = this.connections.get(otherId);
      if (!conn) continue;
      conn.sendText(JSON.stringify({ type: 'presence', kind: online ? 'online' : 'offline', userIds: [userId] }));
    }
  }
}

module.exports = { Presence };
