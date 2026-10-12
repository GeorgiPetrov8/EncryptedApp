#!/usr/bin/env node
'use strict';

/**
 * End-to-end smoke test against a real (in-process, in-memory-DB) instance
 * of this server. Exercises the REST + WebSocket surface the Swift client's
 * `RealAPIClient`/`RealWebSocketService` talk to, using Node's own built-in
 * `fetch` and `WebSocket` client (both standard since Node 22) rather than
 * any test framework or mock — this is the closest thing to "does the wire
 * protocol actually work" available without a Swift toolchain.
 *
 * Run with: `node test/smoke.js` (or `npm test`).
 */

const assert = require('node:assert/strict');
const crypto = require('node:crypto');

process.env.NODE_ENV = 'test'; // in-memory DB, see server.js
process.env.PORT = process.env.PORT || '8091';

const { main } = require('../server.js');

const BASE = `http://127.0.0.1:${process.env.PORT}`;
const WS_BASE = `ws://127.0.0.1:${process.env.PORT}`;

function randomBase64(byteLength) {
  return crypto.randomBytes(byteLength).toString('base64');
}

function fakeBundleUpload(userId, username, otkCount = 3) {
  return {
    userId,
    username,
    identityAgreementKey: randomBase64(32),
    identitySigningKey: randomBase64(32),
    signedPreKeyId: 1,
    signedPreKey: randomBase64(32),
    signedPreKeySignature: randomBase64(64),
    oneTimePreKeys: Array.from({ length: otkCount }, (_, i) => ({
      id: i,
      publicKey: randomBase64(32),
    })),
  };
}

async function json(method, path, { token, body } = {}) {
  const res = await fetch(BASE + path, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let parsed = null;
  if (text) {
    try { parsed = JSON.parse(text); } catch { parsed = text; }
  }
  return { status: res.status, body: parsed };
}

function connectAndAuth(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS_BASE}/ws`);
    const received = [];
    const timeout = setTimeout(() => reject(new Error('WS auth timed out')), 4000);

    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ type: 'auth', token }));
    });
    ws.addEventListener('message', (event) => {
      const msg = JSON.parse(event.data);
      if (msg.type === 'authOk') {
        clearTimeout(timeout);
        resolve({ ws, received });
      } else {
        received.push(msg);
      }
    });
    ws.addEventListener('error', (err) => reject(err));
  });
}

function waitForMessage(received, predicate, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const poll = () => {
      const idx = received.findIndex(predicate);
      if (idx !== -1) return resolve(received[idx]);
      if (Date.now() - start > timeoutMs) return reject(new Error('timed out waiting for message'));
      setTimeout(poll, 25);
    };
    poll();
  });
}

let failures = 0;
async function test(name, fn) {
  try {
    await fn();
    console.log(`  ok  - ${name}`);
  } catch (err) {
    failures += 1;
    console.error(`FAIL  - ${name}`);
    console.error('       ', err && err.stack ? err.stack : err);
  }
}

async function run() {
  const { server } = main();
  console.log(`smoke test server up on ${BASE}`);

  let aliceId, aliceToken, bobId, bobToken;

  await test('healthz responds', async () => {
    const r = await json('GET', '/healthz');
    assert.equal(r.status, 200);
    assert.equal(r.body.status, 'ok');
  });

  await test('register alice', async () => {
    aliceId = crypto.randomUUID();
    const bundle = fakeBundleUpload(aliceId, 'alice');
    const r = await json('POST', '/auth/register', { body: { username: 'alice', bundle } });
    assert.equal(r.status, 201, JSON.stringify(r.body));
    assert.equal(r.body.userId, aliceId);
    assert.ok(r.body.token && r.body.token.length > 20);
    aliceToken = r.body.token;
  });

  await test('register bob', async () => {
    bobId = crypto.randomUUID();
    const bundle = fakeBundleUpload(bobId, 'bob', 2);
    const r = await json('POST', '/auth/register', { body: { username: 'bob', bundle } });
    assert.equal(r.status, 201, JSON.stringify(r.body));
    bobToken = r.body.token;
  });

  await test('duplicate username is rejected', async () => {
    const bundle = fakeBundleUpload(crypto.randomUUID(), 'alice', 1);
    const r = await json('POST', '/auth/register', { body: { username: 'alice', bundle } });
    assert.equal(r.status, 409);
    assert.equal(r.body.error, 'usernameTaken');
  });

  await test('malformed key material is rejected', async () => {
    const bundle = fakeBundleUpload(crypto.randomUUID(), 'carol', 1);
    bundle.identityAgreementKey = 'not-valid-base64!!!';
    const r = await json('POST', '/auth/register', { body: { username: 'carol', bundle } });
    assert.equal(r.status, 400);
  });

  await test('login resolves username to the same userId', async () => {
    const r = await json('POST', '/auth/login', { body: { username: 'alice' } });
    assert.equal(r.status, 200);
    assert.equal(r.body.userId, aliceId);
    assert.notEqual(r.body.token, aliceToken); // fresh token per login
  });

  await test('unauthenticated requests are rejected', async () => {
    const r = await json('GET', `/directory/by-id/${bobId}`);
    assert.equal(r.status, 401);
    assert.equal(r.body.error, 'notAuthenticated');
  });

  await test('directory lookup does not consume a one-time prekey', async () => {
    const before = await json('GET', `/directory/by-id/${bobId}`, { token: aliceToken });
    assert.equal(before.status, 200);
    assert.equal(before.body.username, 'bob');

    for (let i = 0; i < 5; i++) {
      await json('GET', `/directory/by-id/${bobId}`, { token: aliceToken });
      await json('GET', `/directory/by-username/bob`, { token: aliceToken });
    }

    const bundle1 = await json('GET', `/bundles/by-id/${bobId}`, { token: aliceToken });
    assert.equal(bundle1.body.oneTimePreKeyId, 0, 'first bundle fetch must still get prekey id 0');
  });

  await test('bundle fetch consumes a distinct one-time prekey each time', async () => {
    const second = await json('GET', `/bundles/by-id/${bobId}`, { token: aliceToken });
    assert.equal(second.body.oneTimePreKeyId, 1, 'second peer must get a different prekey than the first');

    const third = await json('GET', `/bundles/by-id/${bobId}`, { token: aliceToken });
    assert.equal(third.body.oneTimePreKeyId, null, 'pool of 2 is now exhausted; bundle must still be served without one');
    assert.ok(third.body.signedPreKey, 'the rest of the bundle stays usable once the pool is empty');
  });

  await test('replenish tops the pool back up', async () => {
    const keys = [{ id: 10, publicKey: randomBase64(32) }, { id: 11, publicKey: randomBase64(32) }];
    const r = await json('POST', '/prekeys/one-time', { token: bobToken, body: { userId: bobId, keys } });
    assert.equal(r.status, 204);

    const bundle = await json('GET', `/bundles/by-id/${bobId}`, { token: aliceToken });
    assert.equal(bundle.body.oneTimePreKeyId, 10);
  });

  await test('cannot replenish another account\'s prekeys', async () => {
    const r = await json('POST', '/prekeys/one-time', {
      token: aliceToken,
      body: { userId: bobId, keys: [{ id: 99, publicKey: randomBase64(32) }] },
    });
    assert.equal(r.status, 403);
  });

  await test('signed prekey rotation is published and served', async () => {
    const newSignedPreKey = randomBase64(32);
    const r = await json('POST', '/prekeys/signed', {
      token: bobToken,
      body: { userId: bobId, signedPreKeyId: 2, signedPreKey: newSignedPreKey, signedPreKeySignature: randomBase64(64) },
    });
    assert.equal(r.status, 204);

    const bundle = await json('GET', `/bundles/by-id/${bobId}`, { token: aliceToken });
    assert.equal(bundle.body.signedPreKeyId, 2);
    assert.equal(bundle.body.signedPreKey, newSignedPreKey);
  });

  let bobSocket;
  await test('bob connects and authenticates over WebSocket', async () => {
    const { ws, received } = await connectAndAuth(bobToken);
    bobSocket = { ws, received };
  });

  await test('WebSocket auth rejects an invalid token', async () => {
    await assert.rejects(() => connectAndAuth('not-a-real-token'));
  });

  await test('live delivery: alice sends, bob receives over the open socket', async () => {
    const envelope = {
      id: crypto.randomUUID(),
      conversationId: 'conv-1',
      senderId: aliceId,
      recipientId: bobId,
      kind: 'ratchet',
      handshake: null,
      ratchetMessage: randomBase64(48),
      contentType: 'text',
      createdAt: new Date().toISOString(),
    };
    const r = await json('POST', '/messages', { token: aliceToken, body: envelope });
    assert.equal(r.status, 202);

    const pushed = await waitForMessage(bobSocket.received, (m) => m.type === 'envelope' && m.envelope.id === envelope.id);
    assert.equal(pushed.envelope.senderId, aliceId);
    assert.equal(pushed.envelope.ratchetMessage, envelope.ratchetMessage);

    await json('POST', '/messages/ack', { token: bobToken, body: { envelopeIds: [envelope.id] } });
    const pending = await json('GET', '/messages/pending?since=0', { token: bobToken });
    assert.ok(!pending.body.envelopes.some((e) => e.id === envelope.id), 'acked envelope must be gone from the queue');
  });

  await test('cannot send as another account', async () => {
    const envelope = {
      id: crypto.randomUUID(), conversationId: 'conv-1', senderId: bobId, recipientId: aliceId,
      kind: 'ratchet', handshake: null, ratchetMessage: randomBase64(16), contentType: 'text',
      createdAt: new Date().toISOString(),
    };
    const r = await json('POST', '/messages', { token: aliceToken, body: envelope }); // aliceToken but senderId=bobId
    assert.equal(r.status, 403);
  });

  await test('offline delivery: envelope waits in the durable queue', async () => {
    bobSocket.ws.close();
    await new Promise((r) => setTimeout(r, 100));

    const envelope = {
      id: crypto.randomUUID(), conversationId: 'conv-1', senderId: aliceId, recipientId: bobId,
      kind: 'ratchet', handshake: null, ratchetMessage: randomBase64(32), contentType: 'text',
      createdAt: new Date().toISOString(),
    };
    const sendResult = await json('POST', '/messages', { token: aliceToken, body: envelope });
    assert.equal(sendResult.status, 202);

    const page = await json('GET', '/messages/pending?since=0', { token: bobToken });
    assert.equal(page.status, 200);
    const found = page.body.envelopes.find((e) => e.id === envelope.id);
    assert.ok(found, 'offline envelope must be waiting in the pending queue');
    assert.equal(typeof page.body.cursor, 'number');

    await json('POST', '/messages/ack', { token: bobToken, body: { envelopeIds: [envelope.id] } });
  });

  await test('duplicate envelope id is not double-queued (idempotent send)', async () => {
    const envelope = {
      id: crypto.randomUUID(), conversationId: 'conv-1', senderId: aliceId, recipientId: bobId,
      kind: 'ratchet', handshake: null, ratchetMessage: randomBase64(16), contentType: 'text',
      createdAt: new Date().toISOString(),
    };
    await json('POST', '/messages', { token: aliceToken, body: envelope });
    await json('POST', '/messages', { token: aliceToken, body: envelope }); // resend, e.g. after a dropped ack

    const page = await json('GET', '/messages/pending?since=0', { token: bobToken });
    const matches = page.body.envelopes.filter((e) => e.id === envelope.id);
    assert.equal(matches.length, 1, 'a resent envelope id must not create a second queue entry');

    await json('POST', '/messages/ack', { token: bobToken, body: { envelopeIds: [envelope.id] } });
  });

  await test('media round-trips as opaque bytes', async () => {
    const blob = crypto.randomBytes(4096);
    const uploadRes = await fetch(`${BASE}/media`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${aliceToken}`, 'Content-Type': 'application/octet-stream' },
      body: blob,
    });
    assert.equal(uploadRes.status, 201);
    const { mediaId } = await uploadRes.json();

    const downloadRes = await fetch(`${BASE}/media/${mediaId}`, {
      headers: { Authorization: `Bearer ${bobToken}` }, // any authenticated account, not just the uploader
    });
    assert.equal(downloadRes.status, 200);
    const downloaded = Buffer.from(await downloadRes.arrayBuffer());
    assert.ok(downloaded.equals(blob), 'downloaded bytes must match the uploaded ciphertext exactly');
  });

  await test('notePad content type is accepted and delivered like any other envelope', async () => {
    // The server never interprets this payload — it's ciphertext to it,
    // same as a text message. This just proves the 'notePad' contentType
    // added to validate.js's allow-list actually reaches the recipient's
    // durable queue and live push, unmodified.
    const { ws, received } = await connectAndAuth(bobToken);
    const envelope = {
      id: crypto.randomUUID(), conversationId: 'conv-1', senderId: aliceId, recipientId: bobId,
      kind: 'ratchet', handshake: null,
      ratchetMessage: randomBase64(24), // stands in for an encrypted NotePadOperation
      contentType: 'notePad',
      createdAt: new Date().toISOString(),
    };
    const sendResult = await json('POST', '/messages', { token: aliceToken, body: envelope });
    assert.equal(sendResult.status, 202);

    const pushed = await waitForMessage(received, (m) => m.type === 'envelope' && m.envelope.id === envelope.id);
    assert.equal(pushed.envelope.contentType, 'notePad');

    await json('POST', '/messages/ack', { token: bobToken, body: { envelopeIds: [envelope.id] } });
    ws.close();
  });

  await test('auth rate limit engages after repeated attempts', async () => {
    let sawRateLimit = false;
    for (let i = 0; i < 15; i++) {
      const r = await json('POST', '/auth/login', { body: { username: 'no-such-user' } });
      if (r.status === 429) { sawRateLimit = true; break; }
      assert.equal(r.status, 404);
    }
    assert.ok(sawRateLimit, 'expected the auth rate limiter to trip within 15 rapid attempts');
  });

  console.log(failures === 0 ? '\nAll smoke tests passed.' : `\n${failures} smoke test(s) failed.`);
  server.close(() => process.exit(failures === 0 ? 0 : 1));
}

run().catch((err) => {
  console.error('Smoke test crashed:', err);
  process.exit(1);
});
