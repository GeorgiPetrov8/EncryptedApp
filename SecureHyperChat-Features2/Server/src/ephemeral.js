'use strict';

/**
 * Ephemeral, never-stored signals between mutual contacts:
 *   #3 typing   { type: 'typing',  to, state: 'start'|'stop' }
 *   #9 battery  { type: 'battery', level: 0..100 | null, charging }
 *
 * Nothing here touches the database. Everything lives in memory and is gone on
 * restart or disconnect.
 *
 * Who receives what:
 *   - only MUTUAL contacts (A lists B and B lists A). A client can't make
 *     itself receive someone's typing/battery just by putting them in its own
 *     contacts frame.
 *   - nothing from a user who hid their presence ("Show when I'm online" off).
 *   - typing only to the one person named in `to`; battery to every online
 *     mutual contact, and as a snapshot when a contact (re)sends its list.
 *
 * Limits: typing at most 1 frame / 2 s per sender→recipient pair (the client
 * already throttles); battery at most 1 frame / 20 s per sender.
 */
class Ephemeral {
  constructor({ now = () => Date.now() } = {}) {
    this.now = now;
    this.conns = new Map();      // userId -> conn (sendText)
    this.contacts = new Map();   // userId -> Set(userId)
    this.visible = new Map();    // userId -> bool
    this.battery = new Map();    // userId -> { level, charging, at }
    this.lastTyping = new Map(); // "from|to" -> ms
    this.lastBattery = new Map();// userId -> ms
  }

  register(userId, conn) {
    this.conns.set(userId, conn);
    if (!this.visible.has(userId)) this.visible.set(userId, true);
  }

  /** Call on close — only if `conn` is still the current one. */
  unregister(userId, conn) {
    if (this.conns.get(userId) !== conn) return;
    this.conns.delete(userId);
    if (this.battery.delete(userId)) this._broadcastBattery(userId, null, false);
    this.contacts.delete(userId);
    this.visible.delete(userId);
    this.lastBattery.delete(userId);
    for (const key of this.lastTyping.keys()) {
      if (key.startsWith(userId + '|') || key.endsWith('|' + userId)) this.lastTyping.delete(key);
    }
  }

  setContacts(userId, userIds) {
    if (!Array.isArray(userIds)) return;
    const set = new Set(userIds.filter((id) => typeof id === 'string' && id.length <= 64).slice(0, 500));
    this.contacts.set(userId, set);
    // Snapshot: battery of every mutual contact that is sharing it.
    for (const other of set) {
      const b = this.battery.get(other);
      if (b && this._canSee(userId, other)) {
        this._send(userId, { type: 'battery', from: other, level: b.level, charging: b.charging, at: b.at });
      }
    }
  }

  setVisible(userId, visible) {
    this.visible.set(userId, visible !== false);
    if (visible === false && this.battery.delete(userId)) this._broadcastBattery(userId, null, false);
  }

  /** `to` sees `from`'s signals: mutual contacts, `from` visible. */
  _canSee(to, from) {
    if (to === from) return false;
    if (this.visible.get(from) === false) return false;
    const a = this.contacts.get(from);
    const b = this.contacts.get(to);
    return !!(a && b && a.has(to) && b.has(from));
  }

  _send(userId, frame) {
    const conn = this.conns.get(userId);
    if (!conn) return false;
    try { conn.sendText(JSON.stringify(frame)); return true; } catch { return false; }
  }

  handleTyping(from, data) {
    const to = data && data.to;
    const state = data && data.state;
    if (typeof to !== 'string' || (state !== 'start' && state !== 'stop')) return false;
    if (!this._canSee(to, from)) return false;
    const key = `${from}|${to}`;
    const now = this.now();
    // "stop" always goes through; "start" is throttled.
    const last = this.lastTyping.get(key);
    if (state === 'start' && last !== undefined && now - last < 2000) return false;
    this.lastTyping.set(key, now);
    return this._send(to, { type: 'typing', from, state });
  }

  handleBattery(from, data) {
    const now = this.now();
    const level = data && data.level;
    if (level === null) {
      // Sharing switched off.
      if (this.battery.delete(from)) this._broadcastBattery(from, null, false);
      return true;
    }
    if (!Number.isInteger(level) || level < 0 || level > 100) return false;
    const lastBattery = this.lastBattery.get(from);
    if (lastBattery !== undefined && now - lastBattery < 20_000) return false;
    this.lastBattery.set(from, now);
    const charging = data.charging === true;
    this.battery.set(from, { level, charging, at: new Date(now).toISOString() });
    this._broadcastBattery(from, level, charging);
    return true;
  }

  _broadcastBattery(from, level, charging) {
    const at = new Date(this.now()).toISOString();
    for (const to of this.contacts.get(from) || []) {
      // On removal the visibility flag may already be false: still tell
      // mutual contacts to clear it.
      const mutual = (this.contacts.get(to) || new Set()).has(from);
      if (!mutual) continue;
      if (level !== null && !this._canSee(to, from)) continue;
      this._send(to, { type: 'battery', from, level, charging, at });
    }
  }
}

module.exports = { Ephemeral };
