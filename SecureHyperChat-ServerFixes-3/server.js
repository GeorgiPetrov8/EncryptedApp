#!/usr/bin/env node
'use strict';

const http = require('node:http');
const path = require('node:path');

try {
  process.loadEnvFile(path.join(__dirname, '.env'));
} catch {
  // no .env: fine
}

const { Store } = require('./src/db');
const { Router, dispatch } = require('./src/router');
const { sendJson } = require('./src/json');
const { makeLimiters, clientIp } = require('./src/rateLimit');
const { pruneExpiredSessions, resolveToken } = require('./src/auth');
const { isWebSocketUpgrade, performHandshake, WebSocketConnection } = require('./src/ws');
const recovery = require('./src/routes/recoveryRoutes');
const account = require('./src/routes/accountRoutes');
const { APNsClient } = require('./src/apns');
const { Presence } = require('./src/presence');
const { Ntfy } = require('./src/ntfy');
const mailer = require('./src/mailer');
const ntfyRoutes = require('./src/routes/ntfyRoutes');
const { registerRoute, loginChallengeRoute, loginRoute, logoutRoute } = require('./src/routes/authRoutes');
const {
  replenishOneTimePreKeysRoute, publishSignedPreKeyRoute, directoryByIdRoute,
  directoryByUsernameRoute, bundleByIdRoute, bundleByUsernameRoute,
} = require('./src/routes/prekeyRoutes');
const {
  sendMessageRoute, fetchPendingRoute, fetchByConversationRoute, acknowledgeRoute,
} = require('./src/routes/messageRoutes');
const { uploadMediaRoute, downloadMediaRoute } = require('./src/routes/mediaRoutes');

const PORT = Number(process.env.PORT || 8080);
const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'data', 'securechat.sqlite');

const DAY_MS = 24 * 60 * 60 * 1000;
const WS_AUTH_TIMEOUT_MS = 5000;
const HEARTBEAT_INTERVAL_MS = Number(process.env.HEARTBEAT_INTERVAL_MS) || 30_000;
const WS_PRE_AUTH_MAX_BYTES = 4 * 1024;
const WS_MAX_MESSAGE_BYTES = 64 * 1024;
const WS_FRAMES_PER_WINDOW = 40;
const WS_FRAME_WINDOW_MS = 10_000;
/** Not-yet-authenticated sockets: per IP and in total. */
const WS_MAX_PREAUTH_PER_IP = 10;
const WS_MAX_PREAUTH_TOTAL = 1000;
const MAX_CONNECTIONS = Number(process.env.MAX_CONNECTIONS) || 5000;

const PENDING_RETENTION_MS = (Number(process.env.PENDING_RETENTION_DAYS) || 90) * DAY_MS;
const MEDIA_RETENTION_MS = (Number(process.env.MEDIA_RETENTION_DAYS) || 90) * DAY_MS;
const DEVICE_TOKEN_STALE_MS = 180 * DAY_MS;

function parseRequestUrl(rawUrl) {
  if (typeof rawUrl !== 'string' || !rawUrl.startsWith('/') || rawUrl.startsWith('//')) return null;
  try {
    const parsed = new URL(rawUrl, 'http://internal');
    return { pathname: parsed.pathname, searchParams: parsed.searchParams };
  } catch {
    return null;
  }
}

function main() {
  recovery.assertConfigured();

  const store = new Store(process.env.NODE_ENV === 'test' ? ':memory:' : DB_PATH);
  const limiters = makeLimiters();
  const presence = new Presence();
  const router = new Router();
  const apns = APNsClient.fromEnv();
  const ntfy = new Ntfy(store);

  if (process.env.NODE_ENV === 'production') {
    if (!mailer.isConfigured()) console.warn('[startup] email is NOT configured: recovery codes cannot be sent');
    if (!apns) console.warn('[startup] Apple push is not configured (ntfy still works)');
    if (process.env.ALLOW_UNSIGNED_EMAIL_CHANGE === '1') console.warn('[startup] ALLOW_UNSIGNED_EMAIL_CHANGE=1 — recovery-email changes accept a bare token. Remove it once the app is updated.');
    if ((process.env.SPK_SIGNATURE_CHECK || 'warn') !== 'enforce') console.warn('[startup] SPK_SIGNATURE_CHECK is not "enforce"');
    if (!process.env.TRUST_PROXY) console.warn('[startup] TRUST_PROXY unset: rate limits use the socket address (wrong behind Caddy/Cloudflare)');
  }

  router.post('/auth/register', registerRoute(store, limiters));
  router.post('/auth/login/challenge', loginChallengeRoute(store, limiters));
  router.post('/auth/login', loginRoute(store, limiters));
  router.post('/auth/logout', logoutRoute(store));

  router.get('/account/email', recovery.getEmailRoute(store));
  router.post('/account/email', recovery.setEmailRoute(store, limiters));
  router.post('/account/email/verify', recovery.verifyEmailRoute(store, limiters));
  router.post('/account/email/remove', recovery.removeEmailRoute(store, limiters));
  router.post('/backup', recovery.uploadBackupRoute(store, limiters));
  router.post('/backup/delete', recovery.deleteBackupRoute(store, limiters));
  router.post('/recovery/start', recovery.startRecoveryRoute(store, limiters));
  router.post('/recovery/verify', recovery.verifyRecoveryRoute(store, limiters));
  router.get('/recovery/backup', recovery.downloadBackupRoute(store, limiters));
  router.post('/recovery/rebind', recovery.rebindRoute(store, limiters, { presence, ntfy, apns }));
  router.post('/recovery/cancel', recovery.cancelRecoveryRoute(store, limiters));

  router.post('/account/challenge', account.accountChallengeRoute(store, limiters));
  router.post('/account/delete/challenge', account.deleteChallengeRoute(store, limiters));
  router.post('/account/delete', account.deleteAccountRoute(store, limiters, presence));
  router.post('/devices/push-token', account.registerPushTokenRoute(store, limiters));
  router.post('/devices/push-token/remove', account.removePushTokenRoute(store));
  router.get('/devices/ntfy', ntfyRoutes.getNtfyRoute(store, ntfy));
  router.post('/devices/ntfy', ntfyRoutes.setNtfyRoute(store, limiters, ntfy));
  router.post('/devices/ntfy/test', ntfyRoutes.testNtfyRoute(store, limiters, ntfy));

  router.post('/prekeys/one-time', replenishOneTimePreKeysRoute(store, limiters));
  router.post('/prekeys/signed', publishSignedPreKeyRoute(store, limiters));
  router.get('/directory/by-id/:userId', directoryByIdRoute(store, limiters));
  router.get('/directory/by-username/:username', directoryByUsernameRoute(store, limiters));
  router.get('/bundles/by-id/:userId', bundleByIdRoute(store, limiters));
  router.get('/bundles/by-username/:username', bundleByUsernameRoute(store, limiters));

  router.post('/messages', sendMessageRoute(store, limiters, presence, apns, ntfy));
  router.get('/messages/pending', fetchPendingRoute(store, limiters));
  router.get('/messages', fetchByConversationRoute(store, limiters));
  router.post('/messages/ack', acknowledgeRoute(store, limiters));

  router.post('/media', uploadMediaRoute(store, limiters));
  router.get('/media/:mediaId', downloadMediaRoute(store, limiters));

  router.get('/healthz', async (req, res) => {
    sendJson(res, 200, { status: 'ok' });
  });

  const server = http.createServer((req, res) => {
    const url = parseRequestUrl(req.url);
    if (!url) {
      res.writeHead(400, { Connection: 'close' }).end();
      return;
    }
    dispatch(router, req, res, url).catch((err) => {
      console.error('[http] dispatch failed:', err);
      if (!res.headersSent) res.writeHead(500);
      res.end();
    });
  });

  // Slow-client protection: headers must arrive quickly; a whole request (a 25 MB
  // upload on a slow phone) may take up to two minutes.
  server.headersTimeout = 20_000;
  server.requestTimeout = 120_000;
  server.keepAliveTimeout = 5_000;
  server.maxHeadersCount = 50;
  server.maxConnections = MAX_CONNECTIONS;

  // Relationship check used to filter presence contact lists (S15).
  const isRelated = (a, b) => Boolean(store.stmt.hasRelationship.get(a, b, b, a));

  // --- WebSocket upgrade: GET /ws ---------------------------------------
  const preAuthByIp = new Map();
  let preAuthTotal = 0;

  server.on('upgrade', (req, socket, head) => {
    socket.on('error', () => {});

    const url = parseRequestUrl(req.url);
    if (!url || url.pathname !== '/ws' || !isWebSocketUpgrade(req)) {
      socket.destroy();
      return;
    }

    // Unauthenticated sockets cost memory and a timer each: cap them per IP and
    // in total, and limit how fast one address can open them.
    const ip = clientIp(req);
    const ipCount = preAuthByIp.get(ip) ?? 0;
    if (!limiters.wsUpgrades.take(`ip:${ip}`) || ipCount >= WS_MAX_PREAUTH_PER_IP || preAuthTotal >= WS_MAX_PREAUTH_TOTAL) {
      socket.end('HTTP/1.1 429 Too Many Requests\r\nConnection: close\r\n\r\n');
      return;
    }
    preAuthByIp.set(ip, ipCount + 1);
    preAuthTotal += 1;
    let counted = true;
    const releasePreAuth = () => {
      if (!counted) return;
      counted = false;
      preAuthTotal -= 1;
      const n = (preAuthByIp.get(ip) ?? 1) - 1;
      if (n <= 0) preAuthByIp.delete(ip); else preAuthByIp.set(ip, n);
    };

    const leftover = performHandshake(req, socket, head);
    const conn = new WebSocketConnection(socket, { maxMessageBytes: WS_PRE_AUTH_MAX_BYTES });

    let authenticated = false;
    let heartbeat = null;
    const authTimer = setTimeout(() => {
      if (!authenticated) conn.close(4001, 'auth timeout');
    }, WS_AUTH_TIMEOUT_MS);

    conn.on('close', () => {
      clearTimeout(authTimer);
      if (heartbeat) clearInterval(heartbeat);
      releasePreAuth();
    });

    conn.once('message', (raw) => {
      clearTimeout(authTimer);
      releasePreAuth();

      let msg;
      try { msg = JSON.parse(raw); } catch { conn.close(4002, 'malformed auth frame'); return; }
      if (!msg || msg.type !== 'auth' || typeof msg.token !== 'string') {
        conn.close(4002, 'expected auth frame');
        return;
      }
      const userId = resolveToken(store, msg.token);
      if (!userId) {
        conn.close(4001, 'invalid token');
        return;
      }

      authenticated = true;
      const token = msg.token;
      conn.setMaxMessageBytes(WS_MAX_MESSAGE_BYTES);
      presence.register(userId, conn);
      conn.sendText(JSON.stringify({ type: 'authOk', userId }));

      let windowStart = Date.now();
      let frames = 0;
      conn.on('message', (frame) => {
        const now = Date.now();
        if (now - windowStart > WS_FRAME_WINDOW_MS) { windowStart = now; frames = 0; }
        if (++frames > WS_FRAMES_PER_WINDOW) {
          conn.close(4008, 'too many frames');
          return;
        }
        let data;
        try { data = JSON.parse(frame); } catch { return; }
        if (!data || typeof data !== 'object') return;
        if (data.type === 'contacts') {
          presence.setContacts(userId, data.userIds, isRelated);
        } else if (data.type === 'presenceState') {
          presence.setVisible(userId, data.visible !== false);
        }
      });

      let alive = true;
      conn.on('pong', () => { alive = true; });
      heartbeat = setInterval(() => {
        if (!alive) { conn.close(4004, 'ping timeout'); return; }
        if (!resolveToken(store, token)) { conn.close(4001, 'session ended'); return; }
        alive = false;
        conn.ping();
      }, HEARTBEAT_INTERVAL_MS);
    });

    conn.feed(leftover);
  });

  const housekeeping = setInterval(() => {
    try {
      const now = Date.now();
      const iso = new Date(now).toISOString();
      pruneExpiredSessions(store);
      store.stmt.deleteExpiredLoginChallenges.run(iso);
      store.stmt.deleteExpiredCodes.run(iso);
      store.stmt.deleteExpiredTickets.run(iso);
      // A hold is kept 7 days past its time so the user can still complete it.
      store.stmt.deleteExpiredHolds.run(new Date(now - 7 * DAY_MS).toISOString());
      store.stmt.deleteExpiredPending.run(new Date(now - PENDING_RETENTION_MS).toISOString());
      store.stmt.deleteExpiredMedia.run(new Date(now - MEDIA_RETENTION_MS).toISOString());
      store.stmt.deleteStaleDeviceTokens.run(new Date(now - DEVICE_TOKEN_STALE_MS).toISOString());
      for (const limiter of Object.values(limiters)) limiter.sweep();
    } catch (err) {
      console.error('[housekeeping] failed:', err);
    }
  }, 10 * 60 * 1000);
  housekeeping.unref();

  server.listen(PORT, () => {
    const where = process.env.NODE_ENV === 'test' ? ':memory:' : DB_PATH;
    console.log(`Server listening on :${server.address().port} (db: ${where}, schema v${store.schemaVersion})`);
  });

  let shuttingDown = false;
  function shutdown(exitCode = 0) {
    if (shuttingDown) return;
    shuttingDown = true;
    clearInterval(housekeeping);
    setTimeout(() => process.exit(1), 5000).unref();
    presence.closeAll(1001, 'server shutting down');
    apns?.close();
    server.close(() => {
      try { store.close(); } catch { /* already closed */ }
      process.exit(exitCode);
    });
    server.closeAllConnections?.();
  }

  return { server, store, presence, limiters, shutdown };
}

if (require.main === module) {
  const { shutdown } = main();
  process.on('SIGINT', () => shutdown(0));
  process.on('SIGTERM', () => shutdown(0));
  process.on('unhandledRejection', (reason) => console.error('[unhandledRejection]', reason));
  process.on('uncaughtException', (err) => {
    console.error('[uncaughtException]', err);
    process.exit(1);
  });
}

module.exports = { main, parseRequestUrl };
