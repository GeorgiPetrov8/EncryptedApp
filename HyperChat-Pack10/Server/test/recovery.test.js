'use strict';
const assert = require('node:assert/strict');
const http = require('node:http');
const mailer = require('../src/mailer');
const mailbox = [];
mailer.sendMail = async (m) => { mailbox.push(m); };

const { Store } = require('../src/db');
const R = require('../src/routes/recoveryRoutes');
const { issueToken } = require('../src/auth');

const store = new Store(':memory:');
const L = { auth: {}, media: {} };
const routes = {
  'GET /account/email': R.getEmailRoute(store),
  'POST /account/email': R.setEmailRoute(store, L),
  'POST /account/email/verify': R.verifyEmailRoute(store, L),
  'POST /account/email/remove': R.removeEmailRoute(store),
  'POST /backup': R.uploadBackupRoute(store, L),
  'POST /recovery/start': R.startRecoveryRoute(store, L),
  'POST /recovery/verify': R.verifyRecoveryRoute(store, L),
  'GET /recovery/backup': R.downloadBackupRoute(store, L),
  'POST /recovery/rebind': R.rebindRoute(store, L),
};
const server = http.createServer((req, res) => {
  const h = routes[`${req.method} ${req.url}`];
  if (!h) { res.writeHead(404).end(); return; }
  h(req, res).catch(e => { console.error(e); res.writeHead(500).end(); });
});
async function call(method, path, { token, body, raw, headers = {} } = {}) {
  const res = await fetch(`http://127.0.0.1:${server.address().port}${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(raw ? {} : { 'Content-Type': 'application/json' }), ...headers },
    body: raw ?? (body ? JSON.stringify(body) : undefined),
  });
  const buf = Buffer.from(await res.arrayBuffer());
  let json = null; try { json = JSON.parse(buf.toString()); } catch {}
  return { status: res.status, json, buf };
}
const lastCode = () => /(\d{6})/.exec(mailbox.at(-1).text)[1];
const ageCode = (userId, purpose) =>
  store.db.prepare(`UPDATE email_codes SET created_at = ? WHERE user_id = ? AND purpose = ?`)
    .run(new Date(Date.now() - 120_000).toISOString(), userId, purpose);
let n = 0; const t = async (name, fn) => { await fn(); n++; console.log('  ok -', name); };

server.listen(0, async () => {
  try {
    store.stmt.insertAccount.run('u1', 'alice', 'IA', 'IS', 1, 'SPK', 'SIG', new Date().toISOString());
    store.stmt.insertOneTimePreKey.run('u1', 1, 'OLD');
    const token = issueToken(store, 'u1');
    const backupBytes = Buffer.concat([Buffer.from('HCBK'), Buffer.alloc(100, 7)]);

    await t('email is not active until the code is confirmed', async () => {
      const r = await call('POST', '/account/email', { token, body: { email: '  Alice@Example.COM ' } });
      assert.equal(r.status, 202);
      assert.equal(mailbox.at(-1).to, 'alice@example.com');
      const g = await call('GET', '/account/email', { token });
      assert.equal(g.json.email, null);
      assert.equal(g.json.pendingEmail, 'alice@example.com');
    });

    await t('invalid email rejected', async () => {
      const r = await call('POST', '/account/email', { token, body: { email: 'nope' } });
      assert.equal(r.status, 400);
    });

    await t('resend cooldown', async () => {
      const r = await call('POST', '/account/email', { token, body: { email: 'alice@example.com' } });
      assert.equal(r.status, 429);
    });

    await t('wrong code rejected, right code verifies', async () => {
      const code = lastCode();
      const bad = await call('POST', '/account/email/verify', { token, body: { code: code === '000000' ? '111111' : '000000' } });
      assert.equal(bad.json.error, 'wrongCode');
      const ok = await call('POST', '/account/email/verify', { token, body: { code } });
      assert.equal(ok.status, 200);
      assert.equal((await call('GET', '/account/email', { token })).json.verified, true);
    });

    await t('code is single-use', async () => {
      const again = await call('POST', '/account/email/verify', { token, body: { code: '123456' } });
      assert.equal(again.json.error, 'noCode');
    });

    await t('changing a verified email notifies the old address', async () => {
      mailbox.length = 0; ageCode('u1', 'verify');
      await call('POST', '/account/email', { token, body: { email: 'new@example.com' } });
      assert.equal(mailbox.length, 2);
      assert.equal(mailbox[1].to, 'alice@example.com');
      assert.match(mailbox[1].subject, /change requested/);
      // Old address stays the recovery email until the new one is confirmed.
      assert.equal((await call('GET', '/account/email', { token })).json.email, 'alice@example.com');
      store.stmt.deleteCode.run('u1', 'verify');
    });

    await t('backup upload: rejects non-backups, accepts HCBK', async () => {
      assert.equal((await call('POST', '/backup', { token, raw: Buffer.alloc(100) })).status, 400);
      assert.equal((await call('POST', '/backup', { token, raw: backupBytes })).status, 204);
    });

    await t('recovery/start gives identical answers for real, unknown and email-less accounts', async () => {
      store.stmt.insertAccount.run('u2', 'bob', 'IA', 'IS', 1, 'SPK', 'SIG', new Date().toISOString());
      mailbox.length = 0;
      const a = await call('POST', '/recovery/start', { body: { username: 'alice' } });
      const b = await call('POST', '/recovery/start', { body: { username: 'nobody' } });
      const c = await call('POST', '/recovery/start', { body: { username: 'bob' } });
      assert.deepEqual([a.status, b.status, c.status], [202, 202, 202]);
      assert.deepEqual(a.json, b.json); assert.deepEqual(a.json, c.json);
      assert.equal(mailbox.length, 1, 'only the account with a verified email gets mail');
    });

    await t('5 wrong attempts burn the code (no brute force)', async () => {
      const code = lastCode();
      for (let i = 0; i < 5; i++) {
        const wrong = String((Number(code) + 1 + i) % 1e6).padStart(6, '0');
        await call('POST', '/recovery/verify', { body: { username: 'alice', code: wrong } });
      }
      const r = await call('POST', '/recovery/verify', { body: { username: 'alice', code } });
      assert.equal(r.json.error, 'tooManyAttempts');
    });

    let ticket;
    await t('right code yields a ticket that reports the backup', async () => {
      ageCode('u1', 'recover');
      await call('POST', '/recovery/start', { body: { username: 'ALICE' } }); // case-insensitive
      const r = await call('POST', '/recovery/verify', { body: { username: 'alice', code: lastCode() } });
      assert.equal(r.status, 200);
      assert.equal(r.json.userId, 'u1');
      assert.equal(r.json.hasBackup, true);
      ticket = r.json.ticket;
    });

    await t('the ticket is NOT a messaging token', async () => {
      const r = await call('GET', '/account/email', { token: ticket });
      assert.equal(r.status, 401);
    });

    await t('ticket downloads the exact backup bytes', async () => {
      const r = await call('GET', '/recovery/backup', { headers: { 'X-Recovery-Ticket': ticket } });
      assert.equal(r.status, 200);
      assert.ok(r.buf.equals(backupBytes));
      assert.equal((await call('GET', '/recovery/backup', { headers: { 'X-Recovery-Ticket': 'forged' } })).status, 401);
    });

    await t('rebind refuses a bundle for another account', async () => {
      const r = await call('POST', '/recovery/rebind', { body: { ticket, bundle: {
        userId: 'u2', username: 'bob', identityAgreementKey: 'X', identitySigningKey: 'Y',
        signedPreKeyId: 2, signedPreKey: 'S', signedPreKeySignature: 'G', oneTimePreKeys: [] } } });
      assert.equal(r.status, 400);
    });

    await t('rebind replaces keys, clears queue/sessions/backup, returns a token, emails owner', async () => {
      store.stmt.insertPendingEnvelope.get('e1', 'c', 'u2', 'u1', 'ratchet', null, 'm', 'text', new Date().toISOString());
      mailbox.length = 0;
      const r = await call('POST', '/recovery/rebind', { body: { ticket, bundle: {
        userId: 'u1', username: 'alice', identityAgreementKey: 'NEWIA', identitySigningKey: 'NEWIS',
        signedPreKeyId: 9, signedPreKey: 'NEWSPK', signedPreKeySignature: 'NEWSIG',
        oneTimePreKeys: [{ id: 1, publicKey: 'N1' }, { id: 2, publicKey: 'N2' }] } } });
      assert.equal(r.status, 200);
      const acct = store.stmt.accountById.get('u1');
      assert.equal(acct.identity_agreement_key, 'NEWIA');
      assert.equal(store.stmt.countOneTimePreKeys.get('u1').n, 2);
      assert.equal(store.stmt.pendingCountForUser.get('u1').n, 0);
      assert.equal(store.stmt.backupInfoForUser.get('u1'), undefined);
      assert.equal((await call('GET', '/account/email', { token })).status, 401, 'old device signed out');
      assert.equal((await call('GET', '/account/email', { token: r.json.token })).status, 200);
      assert.match(mailbox.at(-1).subject, /recovered/);
    });

    await t('ticket is single-use after rebind', async () => {
      const r = await call('GET', '/recovery/backup', { headers: { 'X-Recovery-Ticket': ticket } });
      assert.equal(r.status, 401);
    });

    console.log(`\n${n} recovery tests passed`);
  } catch (e) {
    console.error('FAILED:', e);
    process.exitCode = 1;
  } finally {
    server.close();
  }
});
