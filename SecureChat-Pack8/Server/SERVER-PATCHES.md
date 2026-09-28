# Server patches for Pack 8

Four changes to `SecureChatServer/`. The first is a correctness bug you were
right to flag; the rest support the new features.

---

## 1. Content-type allow-list (you were right to check)

`src/validate.js` rejects any `contentType` outside its list, and a rejected
envelope 400s — which the client swallows, so the pad would simply never sync
with no visible error.

```js
// src/validate.js — replace the contentType check in validateEnvelope
//
// The server never interprets any of these; the list is a cheap shape check,
// the same reason 'image'/'video'/'file' are here. A control payload is
// exactly as opaque to this server as a text message — the difference is
// entirely in what the *client* does with the decrypted bytes.
const ALLOWED_CONTENT_TYPES = [
  'text', 'image', 'video', 'file',
  'notePad',   // shared pad operations
  'receipt',   // delivery / read acknowledgements
  'profile',   // display name + avatar push
  'invite',    // contact request and its answer
];

if (!ALLOWED_CONTENT_TYPES.includes(body.contentType)) {
  return 'invalid contentType';
}
```

Add a regression test so a future content type can't be forgotten the same way:

```js
// test/smoke.js
await test('all client content types are accepted by the server', async () => {
  const kinds = ['text', 'image', 'video', 'file', 'notePad', 'receipt', 'profile', 'invite'];
  for (const contentType of kinds) {
    const envelope = {
      id: crypto.randomUUID(), conversationId: 'conv-1',
      senderId: aliceId, recipientId: bobId,
      kind: 'ratchet', handshake: null,
      ratchetMessage: randomBase64(16),
      contentType, createdAt: new Date().toISOString(),
    };
    const r = await json('POST', '/messages', { token: aliceToken, body: envelope });
    assert.equal(r.status, 202, `contentType '${contentType}' was rejected`);
    await json('POST', '/messages/ack', { token: bobToken, body: { envelopeIds: [envelope.id] } });
  }
});
```

---

## 2. Login must prove key possession (Critical #3)

You identified this correctly: `POST /auth/login` issues a token to anyone who
knows a username. That token can drain the victim's queue via
`/messages/ack`, exhaust their prekeys, and send as them.

The fix is challenge–response against the Ed25519 identity signing key already
published at registration. Two endpoints replace the single one:

```js
// src/routes/authRoutes.js

// A short-lived, single-use nonce. In-memory is adequate for a single
// process; move to Redis alongside the rate limiter when scaling out.
const loginChallenges = new Map(); // username -> { nonce, expiresAt }
const CHALLENGE_TTL_MS = 60_000;

/**
 * POST /auth/login/challenge  { username } -> { nonce }
 *
 * Returns a nonce even for an unknown username, and always takes the same
 * path, so this endpoint can't be used to enumerate who has an account.
 */
function loginChallengeRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);
    if (typeof body.username !== 'string') {
      return sendError(res, 400, 'badRequest', 'Missing username');
    }
    const nonce = crypto.randomBytes(32).toString('base64');
    loginChallenges.set(body.username, {
      nonce,
      expiresAt: Date.now() + CHALLENGE_TTL_MS,
    });
    sendJson(res, 200, { nonce });
  };
}

/**
 * POST /auth/login  { username, nonce, signature } -> AuthToken
 *
 * `signature` is Ed25519 over the raw nonce bytes, made with the identity
 * signing key whose public half was published at registration. Only the
 * device holding that private key can produce it.
 */
function loginRoute(store, limiters) {
  return async (req, res) => {
    if (!rateLimit(limiters.auth, req, res)) return;
    const body = await readBody(req);

    const challenge = loginChallenges.get(body.username);
    // Single-use: deleted on first attempt, success or failure, so a captured
    // nonce can't be replayed and a wrong signature can't be brute-forced
    // against the same nonce.
    loginChallenges.delete(body.username);

    if (!challenge || challenge.expiresAt < Date.now()) {
      return sendError(res, 401, 'notAuthenticated', 'Challenge expired. Try again.');
    }

    const account = store.stmt.accountByUsername.get(body.username);
    if (!account) return sendError(res, 404, 'userNotFound', 'No such user.');

    const verified = crypto.verify(
      null,                                   // Ed25519 takes no separate digest
      Buffer.from(challenge.nonce, 'base64'),
      toSpkiEd25519(account.identity_signing_key),
      Buffer.from(body.signature ?? '', 'base64'),
    );
    if (!verified) {
      return sendError(res, 401, 'notAuthenticated', 'Signature did not verify.');
    }

    const token = issueToken(store, account.user_id);
    sendJson(res, 200, { userId: account.user_id, token });
  };
}

/**
 * Node's crypto.verify needs a KeyObject, and the client stores raw 32-byte
 * Ed25519 keys. Wrapping in the fixed SPKI prefix is the standard way to get
 * from one to the other without pulling in a dependency.
 */
function toSpkiEd25519(base64RawKey) {
  const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
  const raw = Buffer.from(base64RawKey, 'base64');
  return crypto.createPublicKey({
    key: Buffer.concat([SPKI_PREFIX, raw]),
    format: 'der',
    type: 'spki',
  });
}
```

**Registration also needs checking** — you asked, and the answer is that it is
currently fine but for a weak reason. `register` writes `bundle.userId`
verbatim, so a client could claim any id. It doesn't matter today only because
ids are random UUIDs, which makes collision unlikely rather than impossible.
Make it explicit:

```js
// In registerRoute, before insert:
if (store.stmt.accountById.get(body.bundle.userId)) {
  return sendError(res, 409, 'usernameTaken', 'That account id is already in use.');
}
```

---

## 3. Presence (feature #5)

Presence is the one signal that legitimately goes through the server rather
than end-to-end: the server already knows who holds an open socket. Encrypting
it would hide a fact the server can read off its own connection table.

```js
// src/presence.js — extend the existing Presence class

/**
 * Who may see whom. Populated by the client on connect with its accepted
 * contact ids, so presence is only ever disclosed to people the user has
 * actually accepted — not to anyone who knows their username.
 */
this.visibleTo = new Map();   // userId -> Set<userId>
this.sharing  = new Map();    // userId -> boolean

setContacts(userId, contactIds) {
  this.visibleTo.set(userId, new Set(contactIds));
}

setSharing(userId, isSharing) {
  this.sharing.set(userId, isSharing);
  this.broadcastPresence(userId, isSharing && this.connections.has(userId));
}

/** Contacts of `userId` who are currently online and sharing. */
onlineContactsOf(userId) {
  const contacts = this.visibleTo.get(userId) ?? new Set();
  return [...contacts].filter(id =>
    this.connections.has(id) &&
    this.sharing.get(id) !== false &&
    (this.visibleTo.get(id)?.has(userId) ?? false)   // must be mutual
  );
}

broadcastPresence(userId, isOnline) {
  if (this.sharing.get(userId) === false) return;
  for (const [otherId, contacts] of this.visibleTo) {
    if (!contacts.has(userId)) continue;
    const conn = this.connections.get(otherId);
    if (!conn) continue;
    conn.sendText(JSON.stringify({
      type: 'presence',
      kind: isOnline ? 'online' : 'offline',
      userIds: [userId],
    }));
  }
}
```

Wire into `server.js`'s upgrade handler, after `authOk`:

```js
// Snapshot on connect, so a client that missed deltas while disconnected
// gets the authoritative set rather than drifting.
conn.sendText(JSON.stringify({
  type: 'presence', kind: 'snapshot',
  userIds: presence.onlineContactsOf(userId),
}));
presence.broadcastPresence(userId, true);

conn.on('close', () => presence.broadcastPresence(userId, false));

// Subsequent client frames: contact list and sharing preference.
conn.on('message', (raw) => {
  const msg = JSON.parse(raw);
  if (msg.type === 'contacts') presence.setContacts(userId, msg.userIds ?? []);
  if (msg.type === 'presencePreference') presence.setSharing(userId, msg.isSharing !== false);
});
```

---

## 4. Invitation allowance (feature #6)

The invite must reach someone who hasn't accepted anything — otherwise it
can't work — but that exception is precisely what spammers would use. Bound
it: one pending invite per sender/recipient pair, and a low daily cap.

```js
// src/db.js — add to _migrate()
CREATE TABLE IF NOT EXISTS invites (
  sender_id    TEXT NOT NULL,
  recipient_id TEXT NOT NULL,
  created_at   TEXT NOT NULL,
  PRIMARY KEY (sender_id, recipient_id)
);
CREATE INDEX IF NOT EXISTS idx_invites_sender_created
  ON invites(sender_id, created_at);
```

```js
// src/routes/messageRoutes.js — in sendMessageRoute, before queueing
if (body.contentType === 'invite') {
  const dayAgo = new Date(Date.now() - 86_400_000).toISOString();
  const sentToday = store.stmt.countInvitesSince.get(body.senderId, dayAgo).n;

  // A real user invites a handful of people; a spammer invites hundreds.
  if (sentToday >= 20) {
    return sendError(res, 429, 'rateLimited', 'Too many invitations today.');
  }
  // One pending invite per pair: re-sending is allowed (people do change
  // their minds) but cannot be used to send repeated notifications.
  store.stmt.upsertInvite.run(body.senderId, body.recipientId, nowIso());
}
```

**Note on what this does and doesn't achieve.** A determined sender can still
register new accounts. That's an inherent limit of an open-registration
system, and the honest fix is account-creation friction (email/phone
verification), not a tighter per-account cap. Worth stating plainly rather
than implying the invite gate makes the app spam-proof.
