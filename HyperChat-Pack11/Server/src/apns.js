'use strict';

const crypto = require('node:crypto');
const http2 = require('node:http2');
const fs = require('node:fs');

/**
 * Apple Push Notification service client, zero dependencies.
 *
 * Push is how a closed app learns that something arrived. Because messages
 * are end-to-end encrypted, the server can't say *what* arrived — only that
 * something did, from the envelope's content type (which the server sees
 * anyway). So notifications are generic: "New message", never the text.
 *
 * Configuration (environment):
 *   APNS_KEY_PATH  path to the AuthKey_XXXXXXXXXX.p8 file from Apple
 *   APNS_KEY_ID    the 10-character key id
 *   APNS_TEAM_ID   your 10-character Apple team id
 *   APNS_TOPIC     the app's bundle id, e.g. com.hyperchat.app
 * Without them push is disabled and everything else keeps working.
 */

const HOSTS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
};

// Apple rejects tokens older than an hour and throttles refreshing more
// often than every 20 minutes; 50 minutes sits between the two.
const JWT_LIFETIME_MS = 50 * 60 * 1000;

/** What each content type looks like on the lock screen. `null` = no push. */
const ALERTS = {
  text: { title: 'HyperChat', body: 'New message' },
  image: { title: 'HyperChat', body: 'New photo' },
  video: { title: 'HyperChat', body: 'New video' },
  file: { title: 'HyperChat', body: 'New attachment' },
  invite: { title: 'HyperChat', body: 'New chat invitation' },
  call: { title: 'HyperChat', body: 'Incoming call' },
  // Background bookkeeping — pushing these would be pure noise.
  receipt: null,
  profile: null,
  notePad: null,
  edit: null,
};

const b64url = (buf) => Buffer.from(buf).toString('base64url');

class APNsClient {
  constructor({ keyPem, keyId, teamId, topic, hosts = HOSTS, rejectUnauthorized = true }) {
    this.key = crypto.createPrivateKey(keyPem);
    this.keyId = keyId;
    this.teamId = teamId;
    this.topic = topic;
    this.hosts = hosts;
    this.rejectUnauthorized = rejectUnauthorized;
    this.jwt = null;
    this.jwtIssuedAt = 0;
    this.sessions = new Map();
  }

  static fromEnv(env = process.env) {
    const { APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC } = env;
    if (!APNS_KEY_PATH || !APNS_KEY_ID || !APNS_TEAM_ID || !APNS_TOPIC) return null;
    return new APNsClient({
      keyPem: fs.readFileSync(APNS_KEY_PATH, 'utf8'),
      keyId: APNS_KEY_ID,
      teamId: APNS_TEAM_ID,
      topic: APNS_TOPIC,
    });
  }

  /** ES256 provider token, cached. */
  token() {
    const now = Date.now();
    if (this.jwt && now - this.jwtIssuedAt < JWT_LIFETIME_MS) return this.jwt;
    const header = b64url(JSON.stringify({ alg: 'ES256', kid: this.keyId }));
    const claims = b64url(JSON.stringify({ iss: this.teamId, iat: Math.floor(now / 1000) }));
    // `ieee-p1363` gives the raw r||s form JWS requires (not DER).
    const signature = crypto.sign('sha256', Buffer.from(`${header}.${claims}`), {
      key: this.key,
      dsaEncoding: 'ieee-p1363',
    });
    this.jwt = `${header}.${claims}.${b64url(signature)}`;
    this.jwtIssuedAt = now;
    return this.jwt;
  }

  session(environment) {
    const host = this.hosts[environment] || this.hosts.production;
    let session = this.sessions.get(host);
    if (!session || session.closed || session.destroyed) {
      session = http2.connect(host, { rejectUnauthorized: this.rejectUnauthorized });
      session.on('error', () => this.sessions.delete(host));
      session.on('close', () => this.sessions.delete(host));
      session.unref();
      this.sessions.set(host, session);
    }
    return session;
  }

  /**
   * Sends one notification.
   * @returns {Promise<{status: number, reason?: string}>}
   */
  send(deviceToken, environment, payload, { collapseId } = {}) {
    return new Promise((resolve) => {
      const body = JSON.stringify(payload);
      const headers = {
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        authorization: `bearer ${this.token()}`,
        'apns-topic': this.topic,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'content-type': 'application/json',
      };
      if (collapseId) headers['apns-collapse-id'] = collapseId;

      let request;
      try {
        request = this.session(environment).request(headers);
      } catch (err) {
        resolve({ status: 0, reason: err.message });
        return;
      }
      let status = 0;
      let data = '';
      request.setEncoding('utf8');
      request.on('response', (h) => { status = h[':status']; });
      request.on('data', (chunk) => { data += chunk; });
      request.on('end', () => {
        let reason;
        try { reason = data ? JSON.parse(data).reason : undefined; } catch { reason = data; }
        resolve({ status, reason });
      });
      request.on('error', (err) => resolve({ status: 0, reason: err.message }));
      request.setTimeout(10_000, () => {
        request.close();
        resolve({ status: 0, reason: 'timeout' });
      });
      request.end(body);
    });
  }

  close() {
    for (const s of this.sessions.values()) s.close();
    this.sessions.clear();
  }
}

/**
 * Called after an envelope is queued. Pushes only if the recipient has no
 * live socket (a connected app gets it over the WebSocket instantly) and
 * the content type is user-visible. Prunes tokens Apple says are dead.
 */
async function pushForEnvelope({ apns, store, presence, envelope }) {
  if (!apns) return 0;
  const alert = ALERTS[envelope.contentType];
  if (!alert) return 0;
  if (presence && presence.isOnline(envelope.recipientId)) return 0;

  const tokens = store.stmt.deviceTokensForUser.all(envelope.recipientId);
  let sent = 0;
  for (const { token, environment } of tokens) {
    const result = await apns.send(token, environment, {
      aps: {
        alert,
        sound: 'default',
        'thread-id': envelope.conversationId,
      },
    }, {
      // One "new message" per conversation instead of a stack of identical ones.
      collapseId: `${envelope.contentType}:${envelope.conversationId}`.slice(0, 64),
    });
    if (result.status === 200) {
      sent += 1;
    } else if (result.status === 410 || result.reason === 'BadDeviceToken' || result.reason === 'Unregistered') {
      store.stmt.deleteDeviceToken.run(token);
    } else {
      console.error(`[apns] push failed: ${result.status} ${result.reason ?? ''}`);
    }
  }
  return sent;
}

module.exports = { APNsClient, pushForEnvelope, ALERTS };
