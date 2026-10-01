'use strict';
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { Presence } = require('./presence');

class FakeConn extends EventEmitter {
  constructor() { super(); this.sent = []; this.closed = false; }
  sendText(s) { this.sent.push(JSON.parse(s)); }
  close() { this.closed = true; this.emit('close'); }
  last() { return this.sent[this.sent.length - 1]; }
  presence() { return this.sent.filter((m) => m.type === 'presence'); }
}

let n = 0; const t = (name, fn) => { fn(); n++; console.log('  ok -', name); };
const p = new Presence();
const alice = new FakeConn(), bob = new FakeConn(), eve = new FakeConn();

t('register + contacts: snapshot empty while Bob has not listed Alice', () => {
  p.register('alice', alice); p.setContacts('alice', ['bob']);
  assert.deepEqual(alice.last(), { type: 'presence', kind: 'snapshot', userIds: [] });
});
t('Bob connects and lists Alice -> both see each other (mutual)', () => {
  p.register('bob', bob); p.setContacts('bob', ['alice']);
  assert.deepEqual(bob.last(), { type: 'presence', kind: 'snapshot', userIds: ['alice'] });
  assert.deepEqual(alice.last(), { type: 'presence', kind: 'online', userIds: ['bob'] });
});
t('one-sided contact (Eve lists Alice) leaks nothing either way', () => {
  const beforeAlice = alice.sent.length;
  p.register('eve', eve); p.setContacts('eve', ['alice']);
  assert.deepEqual(eve.last(), { type: 'presence', kind: 'snapshot', userIds: [] });
  assert.equal(alice.sent.length, beforeAlice, 'Alice must not learn about Eve');
});
t('Bob backgrounds the app -> Alice sees offline', () => {
  p.setVisible('bob', false);
  assert.deepEqual(alice.last(), { type: 'presence', kind: 'offline', userIds: ['bob'] });
  p.setContacts('alice', ['bob']);
  assert.deepEqual(alice.last().userIds.includes('bob'), false);
});
t('Bob foregrounds -> online again', () => {
  p.setVisible('bob', true);
  assert.deepEqual(alice.last(), { type: 'presence', kind: 'online', userIds: ['bob'] });
});
t('replaced connection closing does NOT broadcast offline', () => {
  const bob2 = new FakeConn(); const before = alice.sent.length;
  p.register('bob', bob2);
  assert.equal(bob.closed, true);
  assert.equal(alice.sent.length, before);
});
t('current connection closing broadcasts offline', () => {
  p.connections.get('bob').emit('close');
  assert.deepEqual(alice.last(), { type: 'presence', kind: 'offline', userIds: ['bob'] });
});
console.log(`\n${n} presence tests passed`);
