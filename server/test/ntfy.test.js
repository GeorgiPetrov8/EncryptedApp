'use strict';
const assert = require('node:assert/strict');
const http = require('node:http');
const { DatabaseSync } = require('node:sqlite');
const { Ntfy } = require('../src/ntfy');
const R = require('../src/routes/ntfyRoutes');

let n = 0;
const t = async (name, fn) => { await fn(); n++; console.log('  ok -', name); };

// A local server standing in for ntfy.sh.
const received = [];
let ntfyStatus = 200;
const fakeNtfy = http.createServer((req, res) => {
  let body = '';
  req.on('data', (d) => { body += d; });
  req.on('end', () => { received.push({ path: req.url, headers: req.headers, body }); res.writeHead(ntfyStatus).end('{}'); });
});

const db = new DatabaseSync(':memory:');
db.exec('PRAGMA foreign_keys = ON; CREATE TABLE accounts (user_id TEXT PRIMARY KEY);');
db.exec("INSERT INTO accounts VALUES ('alice'), ('bob');");
const store = { db, users: new Set(['alice', 'bob']) };
const L = { auth: {}, prekeys: {} };
let ntfy;
const presence = { isOnline: (id) => id === 'online' };

const TOPIC = 'hc-' + 'a1b2c3d4e5f6g7h8j9k0';

async function main() {
  await new Promise((r) => fakeNtfy.listen(0, r));
  ntfy = new Ntfy(store, { baseUrl: `http://127.0.0.1:${fakeNtfy.address().port}/` });

  const routes = {
    'GET /devices/ntfy': R.getNtfyRoute(store, ntfy),
    'POST /devices/ntfy': R.setNtfyRoute(store, L, ntfy),
    'POST /devices/ntfy/test': R.testNtfyRoute(store, L, ntfy),
  };
  const app = http.createServer((req, res) => {
    const h = routes[`${req.method} ${req.url}`];
    if (!h) return res.writeHead(404).end();
    h(req, res).catch((e) => { console.error(e); res.writeHead(500).end(); });
  });
  await new Promise((r) => app.listen(0, r));
  const call = async (method, path, user, body) => {
    const r = await fetch(`http://127.0.0.1:${app.address().port}${path}`, {
      method, headers: { Authorization: `Bearer ${user}`, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await r.text();
    return { status: r.status, json: text ? JSON.parse(text) : null };
  };
  const env = (contentType, recipientId = 'alice', conversationId = 'c1') => ({ contentType, recipientId, conversationId });

  try {
    await t('off by default', async () => {
      assert.deepEqual((await call('GET', '/devices/ntfy', 'alice')).json, { enabled: false, topic: null });
      assert.equal(await ntfy.notifyForEnvelope(env('text'), presence), false);
      assert.equal(received.length, 0);
    });

    await t('guessable / malformed topics are refused', async () => {
      for (const topic of ['short', 'has space in it xxxxxxxx', 'x'.repeat(65), 'a/b/c/d/e/f/g/h/i/j/k', 42]) {
        assert.equal((await call('POST', '/devices/ntfy', 'alice', { topic })).status, 400, String(topic));
      }
    });

    await t('turn on, then status reflects it', async () => {
      assert.equal((await call('POST', '/devices/ntfy', 'alice', { topic: TOPIC })).status, 204);
      assert.deepEqual((await call('GET', '/devices/ntfy', 'alice')).json, { enabled: true, topic: TOPIC });
    });

    await t('test notification reaches the topic', async () => {
      const r = await call('POST', '/devices/ntfy/test', 'alice');
      assert.equal(r.status, 200);
      assert.equal(received.at(-1).path, `/${TOPIC}`);
      assert.equal(received.at(-1).body, 'Notifications are working.');
    });

    await t('a message sends a generic notification with a tap-to-open link', async () => {
      assert.equal(await ntfy.notifyForEnvelope(env('text'), presence), true);
      const sent = received.at(-1);
      assert.equal(sent.body, 'New message');
      assert.equal(sent.headers.title, 'HyperChat');
      assert.equal(sent.headers.click, 'hyperchat://');
    });

    await t('burst in one conversation = one notification; another conversation still notifies', async () => {
      const before = received.length;
      for (let i = 0; i < 5; i++) await ntfy.notifyForEnvelope(env('text'), presence);
      assert.equal(received.length, before);
      assert.equal(await ntfy.notifyForEnvelope(env('image', 'alice', 'c2'), presence), true);
    });

    await t('calls are never throttled and use top priority', async () => {
      assert.equal(await ntfy.notifyForEnvelope(env('call'), presence), true);
      assert.equal(await ntfy.notifyForEnvelope(env('call'), presence), true);
      assert.equal(received.at(-1).headers.priority, '5');
    });

    await t('no notification for receipts/profile/pad/edit, online users, or users who opted out', async () => {
      const before = received.length;
      for (const ct of ['receipt', 'profile', 'notePad', 'edit']) {
        assert.equal(await ntfy.notifyForEnvelope(env(ct, 'alice', 'c9'), presence), false);
      }
      assert.equal(await ntfy.notifyForEnvelope(env('text', 'online', 'c9'), presence), false);
      assert.equal(await ntfy.notifyForEnvelope(env('text', 'bob', 'c9'), presence), false);
      assert.equal(received.length, before);
    });

    await t('one user cannot see another user\'s topic', async () => {
      assert.deepEqual((await call('GET', '/devices/ntfy', 'bob')).json, { enabled: false, topic: null });
      assert.equal((await call('GET', '/devices/ntfy', 'mallory')).status, 401);
    });

    await t('ntfy down: test reports it, message path does not throw', async () => {
      ntfyStatus = 500;
      assert.equal((await call('POST', '/devices/ntfy/test', 'alice')).status, 502);
      assert.equal(await ntfy.notifyForEnvelope(env('text', 'alice', 'c7'), presence), false);
      ntfyStatus = 200;
    });

    await t('turn off', async () => {
      assert.equal((await call('POST', '/devices/ntfy', 'alice', { topic: null })).status, 204);
      assert.deepEqual((await call('GET', '/devices/ntfy', 'alice')).json, { enabled: false, topic: null });
    });

    await t('deleting the account removes the topic (foreign-key cascade)', async () => {
      ntfy.setTopic('bob', TOPIC);
      db.exec("DELETE FROM accounts WHERE user_id = 'bob'");
      assert.equal(ntfy.topicFor('bob'), null);
    });

    console.log(`\n${n} ntfy tests passed`);
  } catch (e) {
    console.error('FAILED:', e); process.exitCode = 1;
  } finally {
    app.close(); fakeNtfy.close();
  }
}
main();
