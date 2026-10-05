#!/usr/bin/env node
'use strict';
require('dotenv').config({ path: './env.env' });

const http = require('node:http');
const path = require('node:path');

const { Store } = require('./src/db');
const { Router, dispatch } = require('./src/router');
const { sendJson, sendError } = require('./src/json');
const { makeLimiters } = require('./src/rateLimit');
const { pruneExpiredSessions, resolveToken } = require('./src/auth');
const { isWebSocketUpgrade, performHandshake, WebSocketConnection } = require('./src/ws');
const recovery = require('./src/routes/recoveryRoutes');
const account = require('./src/routes/accountRoutes');
const { APNsClient, pushForEnvelope } = require('./src/apns');
const { Presence } = require('./src/presence');
const { Ntfy } = require('./src/ntfy');
const ntfyRoutes = require('./src/routes/ntfyRoutes');


const {
    registerRoute,
    loginChallengeRoute,
    loginRoute,
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
const WS_AUTH_TIMEOUT_MS = 5000;
const HEARTBEAT_INTERVAL_MS = 30_000;
const MEDIA_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;

function main() {
  const store = new Store(process.env.NODE_ENV === 'test' ? ':memory:' : DB_PATH);
  const limiters = makeLimiters();
  const presence = new Presence();

  const router = new Router();
  const apns = APNsClient.fromEnv(); // null, ако не е настроено — всичко друго работи
  const ntfy = new Ntfy(store);
  router.post('/auth/register', registerRoute(store, limiters));
  router.post('/auth/login/challenge', loginChallengeRoute(store, limiters));
  router.post('/auth/login', loginRoute(store, limiters));
  
  router.get('/account/email', recovery.getEmailRoute(store));
  router.post('/account/email', recovery.setEmailRoute(store, limiters));
  router.post('/account/email/verify', recovery.verifyEmailRoute(store, limiters));
  router.post('/account/email/remove', recovery.removeEmailRoute(store));

  router.post('/backup', recovery.uploadBackupRoute(store, limiters));
  router.post('/backup/delete', recovery.deleteBackupRoute(store));

  router.post('/recovery/start', recovery.startRecoveryRoute(store, limiters));
  router.post('/recovery/verify', recovery.verifyRecoveryRoute(store, limiters));
  router.get('/recovery/backup', recovery.downloadBackupRoute(store, limiters));
  router.post('/recovery/rebind', recovery.rebindRoute(store, limiters));
    
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
    sendJson(res, 200, { status: 'ok', connections: presence.count() });
  });

  const server = http.createServer((req, res) => {
    // The legacy `url.parse()` is deprecated (DEP0169) precisely because its
    // lenient parsing has been a source of request-smuggling-style bugs;
    // the WHATWG `URL` constructor is the standardized replacement. The
    // base is a fixed internal placeholder purely to satisfy the
    // constructor's requirement for an absolute URL — only `pathname` and
    // `searchParams` off the result are ever used.
    const parsed = new URL(req.url, 'http://internal');
    dispatch(router, req, res, { pathname: parsed.pathname, searchParams: parsed.searchParams });
  });

  // --- WebSocket upgrade: GET /ws ---------------------------------------
  //
  // Authentication happens as the first *frame*, not as a `?token=...` query
  // parameter. A token in the URL ends up in access logs, browser history
  // (irrelevant for a native app, but the habit is worth keeping), and any
  // intermediary proxy's request log by default; a token sent as the first
  // WebSocket message after the TLS-protected upgrade does not.
    server.on('upgrade', (req, socket, head) => {
        const { pathname } = new URL(req.url, 'http://internal');

        if (pathname !== '/ws' || !isWebSocketUpgrade(req)) {
            socket.destroy();
            return;
        }

        performHandshake(req, socket, head);

        const conn = new WebSocketConnection(socket);

        let authenticated = false;

        const authTimer = setTimeout(() => {
            if (!authenticated) {
                conn.close(4001, 'auth timeout');
            }
        }, WS_AUTH_TIMEOUT_MS);

        let heartbeat = null;

        conn.once('message', (raw) => {
            clearTimeout(authTimer);

            let msg;

            try {
                msg = JSON.parse(raw);
            } catch {
                conn.close(4002, 'malformed auth frame');
                return;
            }

            if (
                !msg ||
                msg.type !== 'auth' ||
                typeof msg.token !== 'string'
            ) {
                conn.close(4002, 'expected auth frame');
                return;
            }

            const userId = resolveToken(store, msg.token);

            if (!userId) {
                conn.close(4001, 'invalid token');
                return;
            }
            
            authenticated = true;

            presence.register(userId, conn);

            conn.sendText(JSON.stringify({ type: 'authOk', userId }));

            conn.on('message', (raw) => {
              let msg;
              try { msg = JSON.parse(raw); } catch { return; }

              if (msg?.type === 'contacts') {
                presence.setContacts(userId, msg.userIds);
              } else if (msg?.type === 'presenceState') {
                presence.setVisible(userId, msg.visible !== false);
              }
            });

            heartbeat = setInterval(() => conn.ping(), HEARTBEAT_INTERVAL_MS);

            conn.on('close', () => clearInterval(heartbeat));

        });

    });

  // Periodic housekeeping: expired sessions and stale rate-limiter entries
  // would otherwise grow the sessions table and the in-memory limiter maps
  // without bound over a long-running process.
    const housekeeping = setInterval(() => {
        const now = new Date();

        pruneExpiredSessions(store);

        store.stmt.deleteExpiredLoginChallenges.run(
            now.toISOString()
        );

        const mediaCutoff = new Date(
            now.getTime() - MEDIA_RETENTION_MS
        ).toISOString();

        store.stmt.deleteExpiredMedia.run(mediaCutoff);

        for (const limiter of Object.values(limiters)) {
            limiter.sweep();
        }
    }, 10 * 60 * 1000);
  housekeeping.unref();

  server.listen(PORT, () => {
    // eslint-disable-next-line no-console
    console.log(`SecureChat server listening on :${PORT} (db: ${process.env.NODE_ENV === 'test' ? ':memory:' : DB_PATH})`);
  });

  function shutdown() {
    server.close(() => {
      store.close();
      process.exit(0);
    });
  }
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);

  return { server, store, presence };
}

if (require.main === module) {
  main();
}

module.exports = { main };
