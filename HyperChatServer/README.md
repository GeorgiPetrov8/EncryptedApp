# SecureChat Server

A real backend for SecureChat: implements every route `APIClientProtocol`
and `WebSocketServiceProtocol` need, backed by a durable SQLite database,
with zero third-party npm dependencies. Everything here — the HTTP router,
the WebSocket protocol (RFC 6455 handshake + frame codec), the rate
limiter — is hand-rolled on top of Node's built-ins (`node:http`,
`node:sqlite`, `node:crypto`) rather than pulled in as packages, because
this was built in an environment with no npm registry access. That turned
out to be a fine constraint to build under: there is exactly one file to
read to understand the WebSocket layer (`src/ws.js`), not a dependency tree.

See the top-level `../README.md` for how this replaces `MockBackendStore`
end-to-end, including the client-side changes.

## Running it

**Locally, no Docker:**
```
npm start
```
Reads `.env` if present (copy `.env.example` first). Listens on `:8080`,
persists to `./data/securechat.sqlite`.

**With Docker (includes automatic-TLS Caddy in front):**
```
docker compose up --build
```
Edit `Caddyfile` first and replace `chat.yourdomain.example` with your real
domain, pointed at this box via DNS.

## Testing it

```
npm test
```
Runs `test/smoke.js`: a real client (Node's built-in `fetch` and
`WebSocket`) driving a real, in-process, in-memory-DB instance of this
server through registration, login, directory lookups, one-time-prekey
pool exhaustion/replenishment, signed prekey rotation, live WebSocket
delivery, offline durable-queue delivery, replay-safe resends, media
upload/download, and rate limiting. This is what was actually run to
validate the routes below — not aspirational documentation.

## Route reference

| Method & path | Auth | Matches `APIClientProtocol` |
|---|---|---|
| `POST /auth/register` | — | `register(username:bundle:)` |
| `POST /auth/login` | — | `login(username:)` |
| `POST /prekeys/one-time` | Bearer | `replenishOneTimePreKeys` |
| `POST /prekeys/signed` | Bearer | `publishSignedPreKey` |
| `GET /directory/by-id/:userId` | Bearer | `fetchDirectoryEntry(userId:)` |
| `GET /directory/by-username/:username` | Bearer | `fetchDirectoryEntry(username:)` |
| `GET /bundles/by-id/:userId` | Bearer | `fetchPreKeyBundle(forUserId:)` |
| `GET /bundles/by-username/:username` | Bearer | `fetchPreKeyBundle(forUsername:)` |
| `POST /messages` | Bearer | `sendMessage(_:)` |
| `GET /messages/pending?since=N` | Bearer | `fetchPendingEnvelopes(userId:since:)` |
| `GET /messages?conversationId=` | Bearer | `fetchEnvelopes(conversationId:)` |
| `POST /messages/ack` | Bearer | `acknowledge(userId:envelopeIds:)` |
| `POST /media` | Bearer | `uploadMedia(data:)` |
| `GET /media/:mediaId` | Bearer | `downloadMedia(mediaId:)` |
| `GET /ws` (WebSocket upgrade) | first-frame | `WebSocketServiceProtocol.events(for:)` |
| `GET /healthz` | — | — |

All bodies/responses are JSON with exact-camelCase keys, `Data` fields as
base64 strings, `Date` fields as ISO-8601 **with milliseconds**. See the
top-level README's "Date encoding" note for why that last detail matters
and where it's handled on the client.

## What's deliberately different from `MockBackendStore`

- **No permanent per-conversation archive.** `MockBackendStore` kept every
  envelope in `envelopesByConversation` forever. This server's
  `pending_envelopes` table holds only what hasn't been acknowledged yet —
  once a client acks, the row is gone. The server relays; it doesn't
  retain. Clients already keep their own decrypted history locally, so a
  server-side archive of ciphertext would be pure downside (bigger breach
  blast radius) for no product benefit.
- **Opaque, revocable bearer tokens, not JWTs.** A JWT can't be revoked
  short of a server-side blocklist — which needs a database anyway. An
  opaque token looked up against a `sessions` table (storing only its
  SHA-256 hash) costs one indexed read per request and is trivially
  revocable, which is what "log out" and any future "sign out other
  devices" actually need.
- **Directory lookups never consume a one-time prekey; bundle fetches
  always do.** This is the same distinction the client's
  `MessagingService.ensureContact` draws — see the comment on
  `src/routes/prekeyRoutes.js`.

## Known limits of this scaffold (single process)

- **Presence and rate limiting are in-memory**, scoped to one Node
  process. Run more than one instance behind a load balancer and each
  instance grants its own separate rate-limit quota, and a WebSocket
  connection registered on instance A is invisible to a `POST /messages`
  handled by instance B (the durable queue still delivers correctly on
  next poll/reconnect — you only lose the low-latency push, not the
  message). Fixing this for real horizontal scaling means: rate limiting
  via Redis `INCR`/`EXPIRE`, and presence via a Redis pub/sub channel (or
  sticky sessions on the load balancer) so any instance can signal "push
  to this user" regardless of which instance holds their socket.
- **SQLite, not Postgres.** See the commented-out block in
  `docker-compose.yml` for exactly what moves if you outgrow this — it's
  contained entirely to `src/db.js`.
- **Media is stored as a SQLite BLOB**, fine for a scaffold, not for
  serving video at scale. Swap `POST /media` to issue a pre-signed
  object-storage upload URL instead of proxying bytes; the `{ mediaId }`
  contract on both sides of that endpoint doesn't need to change.
