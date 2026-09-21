'use strict';

/**
 * Registry of live WebSocket connections, keyed by userId.
 *
 * Mirrors `MockBackendStore.subscribe(userId:)`: a new connection for a
 * user replaces whatever connection that user already had, rather than
 * fanning out to both. That matches the client's own model (one
 * `MessagingService.startListening()` per signed-in account) and keeps
 * "who do I push to" a one-line lookup instead of a broadcast.
 */
class Presence {
  constructor() {
    this.connections = new Map(); // userId -> WebSocketConnection
  }

  register(userId, connection) {
    const existing = this.connections.get(userId);
    if (existing && existing !== connection) {
      existing.close(4000, 'replaced by a newer connection');
    }
    this.connections.set(userId, connection);
    connection.on('close', () => {
      if (this.connections.get(userId) === connection) {
        this.connections.delete(userId);
      }
    });
  }

  /** Pushes an envelope to a connected recipient. No-op if they're offline —
   * the durable queue (see db.js `pending_envelopes`) is what guarantees
   * delivery; this is purely a latency optimisation for the common case. */
  push(userId, envelopeJson) {
    const conn = this.connections.get(userId);
    if (!conn) return false;
    conn.sendText(JSON.stringify({ type: 'envelope', envelope: envelopeJson }));
    return true;
  }

  isOnline(userId) {
    return this.connections.has(userId);
  }

  count() {
    return this.connections.size;
  }
}

module.exports = { Presence };
