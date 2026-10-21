#!/usr/bin/env node
'use strict';

const http = require('node:http');
const path = require('node:path');

// Optional local .env (Node >= 20.12). In Docker the variables come from
// `env_file`, and a real environment variable always wins over the file.
// There is no dotenv dependency any more.
try {
  process.loadEnvFile(path.join(__dirname, '.env'));
} catch {
  // no .env: fine
}

const { Store } = require('./src/db');
const { Router, dispatch } = require('./src/router');
const { sendJson } = require('./src/json');
const { makeLimiters } = require('./src/rateLimit');
const { pruneExpiredSessions, resolveToken } = require('./src/auth');
const { isWebSocketUpgrade, performHandshake, WebSocketConnection } = require('./src/ws');
const recovery = require('./src/routes/recoveryRoutes');
const account = require('./src/routes/accountRoutes');
const { APNsClient } = require('./src/apns');
const { Presence } = require('./src/presence');
const { Ntfy } = require('./src/ntfy');
const mailer = require('./src/mailer');
const ntfyRoutes = require('./src/routes/ntfyRoutes');
const {
  registerRoute,
  loginChallengeRoute,
  loginRoute,
  logoutRoute,
} = require('./src/routes/authRoutes');
const {
  replenishOneTimePreKeysRoute,
  publishSignedPreKeyRoute,
  directoryByIdRoute,
  directoryByUsernameRoute,
  bundleByIdRoute,
  bundleByUsernameRoute,
} = require('./src/routes/prekeyRoutes');
const {
  sendMessageRoute,
  fetchPendingRoute,
  fetchByConversationRoute,
  acknowledgeRoute,
} = require('./src/routes/messageRoutes');
const { uploadMediaRoute, downloadMediaRoute } = require('./src/routes/mediaRoutes');

const PORT = Number(process.env.PORT || 8080);
const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'data', 'securechat.sqlite');

const DAY_MS = 24 * 60 * 60 * 1000;
const WS_AUTH_TIMEOUT_MS = 5000;
const HEARTBEAT_INTERVAL_MS = Number(process.env.HEARTBEAT_INTERVAL_MS) || 30_000;
const WS_PRE_AUTH_MAX_BYTES = 4 * 1024;   // the auth frame is ~100 bytes
const WS_MAX_MESSAGE_BYTES = 64 * 1024;   // contacts / presence frames
const WS_FRAMES_PER_WINDOW = 40;
const WS_FRAME_WINDOW_MS = 10_000;

// Undelivered messages and uploaded files wait this long for their recipient,
// then are removed. Delivered ones are removed on acknowledgement.
const PENDING_RETENTION_MS = (Number(process.env.PENDING_RETENTION_DAYS) || 90) * DAY_MS;
const MEDIA_RETENTION_MS = (Number(process.env.MEDIA_RETENTION_DAYS) || 90) * DAY_MS;
const DEVICE_TOKEN_STALE_MS = 180 * DAY_MS;

/**
 * Parses a request target. Returns null for anything that isn't a plain
 * absolute path. `new URL("//", base)` throws, and a throw in the request
 * listener was an uncaught exception — one request killed the process.
 */
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
  recovery.assertConfigured(); // fails fast in production without CODE_SECRET

  const store = new Store(process.env.NODE_ENV === 'test' ? ':memory:' : DB_PATH);
  const limiters = makeLimiters();
  const presence = new Presence();
  const router = new Router();
  const apns = APNsClient.fromEnv(); // null if not configured — everything else keeps working
  const ntfy = new Ntfy(store);

  if (process.env.NODE_ENV === 'production') {
    if (!mailer.isConfigured()) console.warn('[startup] email is NOT configured: recovery codes cannot be sent');
    if (!apns) console.warn('[startup] Apple push is not configured (ntfy still works)');
  }

  router.post('/auth/register', registerRoute(store, limiters));
  router.post('/auth/login/challenge', loginChallengeRoute(store, limiters));
  router.post('/auth/login', loginRoute(store, limiters));
  router.post('/auth/logout', logoutRoute(store));

  router.get('/account/email', recovery.getEmailRoute(store));
  router.post('/account/email', recovery.setEmailRoute(store, limiters));
  router.post('/account/email/verify', recovery.verifyEmailRoute(store, limiters));
  router.post('/account/email/remove', recovery.removeEmailRoute(store));
  router.post('/backup', recovery.uploadBackupRoute(store, limiters));
  router.post('/backup/delete', recovery.deleteBackupRoute(store));
  router.post('/recovery/start', recovery.startRecoveryRoute(store, limiters));
  router.post('/recovery/verify', recovery.verifyRecoveryRoute(store, limiters));
  router.get('/recovery/backup', recovery.downloadBackupRoute(store, limiters));
  router.post('/recovery/rebind', recovery.rebindRoute(store, limiters, { presence, ntfy }));

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

  // No connection count: this endpoint is unauthenticated.
  router.get('/healthz', async (req, res) => {
    sendJson(res, 200, { status: 'ok' });
  });

  const server = http.createServer((req, res) => {
    const url = parseRequestUrl(req.url);
    if (!url) {
      res.writeHead(400, { Connection: 'close' }).end();
      return;
    }
    // `dispatch` catches everything itself; this is only a last line of defence.
    dispatch(router, req, res, url).catch((err) => {
      console.error('[http] dispatch failed:', err);
      if (!res.headersSent) res.writeHead(500);
      res.end();
    });
  });

  // --- WebSocket upgrade: GET /ws ---------------------------------------
  //
  // Authentication is the first *frame*, not a `?token=` query parameter: a token
  // in the URL ends up in access logs and proxy logs; one sent after the
  // TLS-protected upgrade does not.
  server.on('upgrade', (req, socket, head) => {
    socket.on('error', () => {}); // an error with no listener would be uncaught

    const url = parseRequestUrl(req.url);
    if (!url || url.pathname !== '/ws' || !isWebSocketUpgrade(req)) {
      socket.destroy();
      return;
    }

    const leftover = performHandshake(req, socket, head);
    // Until the peer authenticates it may send only tiny messages.
    const conn = new WebSocketConnection(socket, { maxMessageBytes: WS_PRE_AUTH_MAX_BYTES });

    let authenticated = false;
    let heartbeat = null;
    const authTimer = setTimeout(() => {
      if (!authenticated) conn.close(4001, 'auth timeout');
    }, WS_AUTH_TIMEOUT_MS);

    // Registered first, so the timers are cleared however the socket ends —
    // including when it closes before authenticating.
    conn.on('close', () => {
      clearTimeout(authTimer);
      if (heartbeat) clearInterval(heartbeat);
    });

    conn.once('message', (raw) => {
      clearTimeout(authTimer);

      let msg;
      try {
        msg = JSON.parse(raw);
      } catch {
        conn.close(4002, 'malformed auth frame');
        return;
      }
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
          presence.setContacts(userId, data.userIds);
        } else if (data.type === 'presenceState') {
          presence.setVisible(userId, data.visible !== false);
        }
      });

      // Heartbeat that actually checks the answer: a peer that vanished without
      // closing (phone out of range, NAT timeout) used to stay "online" forever.
      // It also re-checks the session, so logging out ends the socket too.
      let alive = true;
      conn.on('pong', () => { alive = true; });
      heartbeat = setInterval(() => {
        if (!alive) {
          conn.close(4004, 'ping timeout');
          return;
        }
        if (!resolveToken(store, token)) {
          conn.close(4001, 'session ended');
          return;
        }
        alive = false;
        conn.ping();
      }, HEARTBEAT_INTERVAL_MS);
    });

    // Bytes that arrived in the same TCP segment as the upgrade request — the
    // auth frame can be among them — were previously discarded.
    conn.feed(leftover);
  });

  // Periodic housekeeping. Nothing here deletes anything a user still needs:
  // undelivered messages and files get PENDING_/MEDIA_RETENTION_DAYS (90 by
  // default) to reach their recipient.
  const housekeeping = setInterval(() => {
    try {
      const now = Date.now();
      const iso = new Date(now).toISOString();
      pruneExpiredSessions(store);
      store.stmt.deleteExpiredLoginChallenges.run(iso);
      store.stmt.deleteExpiredCodes.run(iso);
      store.stmt.deleteExpiredTickets.run(iso);
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
    console.log(`Server listening on :${PORT} (db: ${where})`);
  });

  let shuttingDown = false;
  function shutdown(exitCode = 0) {
    if (shuttingDown) return;
    shuttingDown = true;
    clearInterval(housekeeping);
    // Without this, a stuck connection kept `server.close()` waiting forever.
    setTimeout(() => process.exit(1), 5000).unref();
    presence.closeAll(1001, 'server shutting down');
    server.close(() => {
      try { store.close(); } catch { /* already closed */ }
      process.exit(exitCode);
    });
    server.closeAllConnections?.();
  }

  return { server, store, presence, shutdown };
}

if (require.main === module) {
  const { shutdown } = main();
  process.on('SIGINT', () => shutdown(0));
  process.on('SIGTERM', () => shutdown(0));
  // A rejected promise nobody awaited: log it and carry on.
  process.on('unhandledRejection', (reason) => console.error('[unhandledRejection]', reason));
  // After an uncaught exception the process state is unknown; log and exit so the
  // supervisor (`restart: unless-stopped`) starts a clean one.
  process.on('uncaughtException', (err) => {
    console.error('[uncaughtException]', err);
    process.exit(1);
  });
}

module.exports = { main, parseRequestUrl };
