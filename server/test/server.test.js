'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const http2 = require('node:http2');
const path = require('node:path');

const { Store } = require('../src/db');
const { issueToken } = require('../src/auth');
const auth = require('../src/routes/authRoutes');
const account = require('../src/routes/accountRoutes');
const { validateEnvelope, ALLOWED_CONTENT_TYPES } = require('../src/validate');
const { APNsClient, pushForEnvelope } = require('../src/apns');

let n = 0;
const t = async (name, fn) => { await fn(); n++; console.log('  ok -', name); };

const store = new Store(':memory:');
const L = { auth: {}, prekeys: {}, media: {} };
const closed = [];
const presence = {
  connections: new Map([['u1', { close: (code) => closed.push(code) }]]),
  forget() {}, isOnline: (id) => id === 'online-user',
};
const routes = {
  'POST /auth/register': auth.registerRoute(store, L),
  'POST /auth/login/challenge': auth.loginChallengeRoute(store, L),
  'POST /auth/login': auth.loginRoute(store, L),
  'POST /account/delete/challenge': account.deleteChallengeRoute(store, L),
  'POST /account/delete': account.deleteAccountRoute(store, L, presence),
  'POST /devices/push-token': account.registerPushTokenRoute(store, L),
};
const server = http.createServer((req, res) => {
  const h = routes[`${req.method} ${req.url}`];
  if (!h) return res.writeHead(404).end();
  h(req, res).catch((e) => { console.error(e); res.writeHead(500).end(); });
});
async function call(p, body, token) {
  const r = await fetch(`http://127.0.0.1:${server.address().port}${p}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body ?? {}),
  });
  const text = await r.text();
  return { status: r.status, json: text ? JSON.parse(text) : null };
}

// A real Ed25519 identity, signed exactly as CryptoKit does (raw 64-byte sig over the nonce bytes).
const ed = crypto.generateKeyPairSync('ed25519');
const rawPub = ed.publicKey.export({ format: 'der', type: 'spki' }).subarray(12);
const sign = (nonceB64, key = ed.privateKey) => crypto.sign(null, Buffer.from(nonceB64, 'base64'), key).toString('base64');
const b64 = (n) => crypto.randomBytes(n).toString('base64');
const bundle = (userId, username) => ({
  userId, username,
  identityAgreementKey: b64(32), identitySigningKey: rawPub.toString('base64'),
  signedPreKeyId: 1, signedPreKey: b64(32), signedPreKeySignature: b64(64),
  oneTimePreKeys: [{ id: 1, publicKey: b64(32) }],
});

server.listen(0, async () => {
  try {
    await t('every client content type passes validation (call + edit were rejected)', async () => {
      for (const contentType of ['text','image','video','file','notePad','receipt','profile','invite','call','edit']) {
        const err = validateEnvelope({ id: 'e', conversationId: 'c'.repeat(64), senderId: 'a', recipientId: 'b',
          kind: 'ratchet', ratchetMessage: b64(10), contentType });
        assert.equal(err, null, `${contentType}: ${err}`);
      }
      assert.equal(ALLOWED_CONTENT_TYPES.length, 10);
    });

    let token;
    await t('register', async () => {
      const r = await call('/auth/register', { username: 'maria', bundle: bundle('u1', 'maria') });
      assert.equal(r.status, 201); token = r.json.token;
    });

    await t('login challenge returns the userId (client needs it to pick keys)', async () => {
      const c = await call('/auth/login/challenge', { username: 'MARIA' });
      assert.equal(c.json.userId, 'u1');
      const ok = await call('/auth/login', { username: 'maria', nonce: c.json.nonce, signature: sign(c.json.nonce) });
      assert.equal(ok.status, 200);
    });

    await t('username-only login (what RealAPIClient sent) is refused', async () => {
      const r = await call('/auth/login', { username: 'maria' });
      assert.equal(r.status, 400);
    });

    await t('wrong key is refused and the nonce is burned', async () => {
      const c = await call('/auth/login/challenge', { username: 'maria' });
      const other = crypto.generateKeyPairSync('ed25519').privateKey;
      assert.equal((await call('/auth/login', { username: 'maria', nonce: c.json.nonce, signature: sign(c.json.nonce, other) })).status, 401);
      assert.equal((await call('/auth/login', { username: 'maria', nonce: c.json.nonce, signature: sign(c.json.nonce) })).json.error, 'invalidChallenge');
    });

    await t('push token registration', async () => {
      assert.equal((await call('/devices/push-token', { token: 'zz' }, token)).status, 400);
      assert.equal((await call('/devices/push-token', { token: 'ab'.repeat(32), environment: 'sandbox' }, token)).status, 204);
      assert.equal(store.stmt.deviceTokensForUser.all('u1').length, 1);
    });

    await t('account deletion needs a signature, not just the token', async () => {
      const r = await call('/account/delete', { nonce: 'x', signature: b64(64) }, token);
      assert.equal(r.status, 401);
      assert.ok(store.stmt.accountById.get('u1'));
    });

    await t('account deletion removes everything and retires the name', async () => {
      store.stmt.insertAccount.run('u2', 'alex', 'a', 'b', 1, 'c', 'd', new Date().toISOString());
      const now = new Date().toISOString();
      store.stmt.insertPendingEnvelope.get('e1', 'c', 'u2', 'u1', 'ratchet', null, 'm', 'text', now);
      store.stmt.insertPendingEnvelope.get('e2', 'c', 'u1', 'u2', 'ratchet', null, 'm', 'text', now);
      store.stmt.upsertInvite.run('u1', 'u2', now);
      store.stmt.upsertVerifiedEmail.run('u1', 'm@example.com', now);
      store.stmt.upsertBackup.run('u1', Buffer.from('HCBK'), 4, now);

      const c = await call('/account/delete/challenge', {}, token);
      const r = await call('/account/delete', { nonce: c.json.nonce, signature: sign(c.json.nonce) }, token);
      assert.equal(r.status, 204);

      assert.equal(store.stmt.accountById.get('u1'), undefined);
      assert.equal(store.stmt.pendingCountForUser.get('u1').n, 0);
      assert.equal(store.stmt.pendingCountForUser.get('u2').n, 0, 'undelivered messages from the deleted user withdrawn');
      assert.equal(store.stmt.emailForUser.get('u1'), undefined);
      assert.equal(store.stmt.backupForUser.get('u1'), undefined);
      assert.equal(store.stmt.deviceTokensForUser.all('u1').length, 0);
      assert.deepEqual(closed, [4003], 'live socket closed');
      assert.equal((await call('/account/delete/challenge', {}, token)).status, 401, 'token revoked');
    });

    await t('a deleted username can never be registered again', async () => {
      const r = await call('/auth/register', { username: 'Maria', bundle: bundle('u9', 'Maria') });
      assert.equal(r.status, 409);
    });

    // ---- APNs against a local HTTP/2 TLS server standing in for Apple ----
    const seen = [];
    const fake = http2.createSecureServer({
      key: fs.readFileSync(path.join(__dirname, 'tls.key')),
      cert: fs.readFileSync(path.join(__dirname, 'tls.crt')),
    });
    fake.on('stream', (stream, headers) => {
      let body = '';
      stream.on('data', (d) => { body += d; });
      stream.on('end', () => {
        seen.push({ headers, body: JSON.parse(body) });
        const dead = headers[':path'].endsWith('dead'.padEnd(64, '0'));
        stream.respond({ ':status': dead ? 410 : 200 });
        stream.end(dead ? JSON.stringify({ reason: 'Unregistered' }) : '');
      });
    });
    await new Promise((r) => fake.listen(0, r));
    const host = `https://localhost:${fake.address().port}`;
    const keyPem = fs.readFileSync(path.join(__dirname, 'authkey.p8'), 'utf8');
    const apns = new APNsClient({ keyPem, keyId: 'ABC123DEFG', teamId: 'TEAM123456', topic: 'com.hyperchat.app',
      hosts: { production: host, sandbox: host }, rejectUnauthorized: false });

    await t('APNs JWT is valid ES256 Apple can verify', async () => {
      const [h, c, s] = apns.token().split('.');
      assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url')), { alg: 'ES256', kid: 'ABC123DEFG' });
      assert.equal(JSON.parse(Buffer.from(c, 'base64url')).iss, 'TEAM123456');
      const ok = crypto.verify('sha256', Buffer.from(`${h}.${c}`), { key: crypto.createPublicKey(keyPem), dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url'));
      assert.ok(ok);
      assert.equal(apns.token(), apns.token(), 'cached');
    });

    store.stmt.insertAccount.run('u3', 'sam', 'a', 'b', 1, 'c', 'd', new Date().toISOString());
    const now = new Date().toISOString();
    store.stmt.upsertDeviceToken.run('ab'.repeat(32), 'u3', 'production', now);
    store.stmt.upsertDeviceToken.run('dead'.padEnd(64, '0'), 'u3', 'sandbox', now);
    const env = (contentType, recipientId = 'u3') => ({ contentType, recipientId, conversationId: 'conv1' });

    await t('offline recipient gets a generic push; dead token is pruned', async () => {
      const sent = await pushForEnvelope({ apns, store, presence, envelope: env('text') });
      assert.equal(sent, 1);
      const push = seen.find((s) => s.headers[':path'].endsWith('ab'.repeat(32)));
      assert.equal(push.headers['apns-topic'], 'com.hyperchat.app');
      assert.match(push.headers.authorization, /^bearer /);
      assert.deepEqual(push.body.aps.alert, { title: 'HyperChat', body: 'New message' });
      assert.equal(JSON.stringify(push.body).includes('ratchet'), false, 'no message content in push');
      assert.equal(store.stmt.deviceTokensForUser.all('u3').length, 1, '410 token removed');
    });

    await t('no push for receipts/profile/pad/edit, or when the recipient is online', async () => {
      const before = seen.length;
      for (const ct of ['receipt', 'profile', 'notePad', 'edit']) {
        assert.equal(await pushForEnvelope({ apns, store, presence, envelope: env(ct) }), 0);
      }
      assert.equal(await pushForEnvelope({ apns, store, presence, envelope: env('text', 'online-user') }), 0);
      assert.equal(seen.length, before);
    });

    apns.close();
    fake.close();
    console.log(`\n${n} server tests passed`);
  } catch (e) {
    console.error('FAILED:', e); process.exitCode = 1;
  } finally {
    server.close();
  }
});
