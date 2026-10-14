# HyperChat hardening — what to change

Layout: `Server/` replaces your server folder; `Client/` holds four Swift files and
`project.yml`; `.gitignore` goes at the repo root. No tests are included.

## 1. Server — replace these files

| File | Why |
|---|---|
| `server.js` | no `dotenv`; bad request targets can't crash it; WebSocket auth/heartbeat/limits; housekeeping; logout route; graceful shutdown |
| `src/router.js` | `%`-escapes can't crash it; `null`/array JSON bodies -> 400 |
| `src/ws.js` | whole-message size cap, tiny pre-auth cap, UTF-8/opcode/RSV checks, no lost first bytes, slow-reader limit |
| `src/presence.js` | forgets users on disconnect, `disconnect()` / `closeAll()`, contact cap, no re-broadcast on unchanged lists |
| `src/db.js` | `received_at`, `uploader_id`, `busy_timeout`, re-entrant transactions, new statements. **Migrates your existing database in place.** |
| `src/json.js` / `src/validate.js` | canonical base64, UUID user ids, `createdAt` checks, only known envelope fields are relayed |
| `src/auth.js` | `revokeToken` |
| `src/rateLimit.js` | key = the proxy's entry with the port stripped; new per-account limiters |
| `src/mailer.js` | `isConfigured()`, provider error is logged, codes aren't printed in production |
| `src/apns.js` | missing key file disables push instead of crashing; hashed thread/collapse ids |
| `src/routes/authRoutes.js` | `POST /auth/logout` |
| `src/routes/messageRoutes.js` | envelope-id clash, duplicate = no second push, queue caps, ack limit |
| `src/routes/prekeyRoutes.js` | one-time prekey drain protection, pool cap |
| `src/routes/mediaRoutes.js` | per-account quota, owner recorded |
| `src/routes/recoveryRoutes.js` | keyed code hashes, signed proof to change the email, rebind cuts off the old device |
| `src/routes/accountRoutes.js` | `/account/challenge`, deletion also removes uploaded files |
| `package.json`, `Dockerfile`, `.dockerignore`, `docker-compose.yml`, `Caddyfile`, `.env.example` | deploy |

Not touched: `src/challenge.js`, `src/envelopeMapper.js`, `src/ntfy.js`, `src/routes/ntfyRoutes.js`.
Delete `env.env`, and delete `node_modules/` from the repo (it is no longer needed).

## 2. Server — configuration

```bash
cd Server
cp .env.example .env
openssl rand -hex 32          # paste into CODE_SECRET=
```
- **`CODE_SECRET` is required when `NODE_ENV=production`** — the server refuses to start without it.
- Fill `RESEND_API_KEY` and `MAIL_FROM`, or recovery codes can't be emailed.
- Apple push (paid account only): put `AuthKey_XXXX.p8` in `Server/keys/`, set
  `APNS_KEY_PATH=/run/keys/AuthKey_XXXX.p8`, `APNS_KEY_ID`, `APNS_TEAM_ID`,
  and `APNS_TOPIC=com.SecureHyperChat.app`.
- Put your real domain in `Caddyfile`.
- Node must be **>= 22.13** (`node:sqlite` without a flag).

```bash
docker compose up --build -d
```

Existing data in the `securechat-data` volume is kept.

## 3. Client — replace these files

`AppLockService.swift`, `NtfyService.swift`, `RecoveryAPI.swift`, `AppContainer.swift`, `project.yml`.

### One edit I couldn't make for you
The server now refuses to set or change the recovery email on a token alone — it needs
a signature from the device key. `RecoveryAPI` has the new call, but the place that
*uses* it is `RecoveryService`, which I haven't seen.

Find where it calls `api.requestEmailCode(email)` (Xcode will show a deprecation warning
there) and change it to pass the same signer your account deletion uses:

```swift
try await api.requestEmailCode(email, prove: <the ChallengeSigner you pass to deleteAccountOnServer>)
```

Until you do, adding an email shows "Confirm this change with this device's key. Update the
app and try again." While you roll the app out you can set `ALLOW_UNSIGNED_EMAIL_CHANGE=1`
in `.env`; remove it afterwards.

## 4. Repo clean-up (do this first)

```bash
git ls-files | grep -E "data/|node_modules|\.env"
```
If anything shows up, `git rm -r --cached` it, then remove it from history
(`git filter-repo --path <path> --invert-paths`) and force-push. Treat every session in a
leaked database as compromised and empty the `sessions` table on the live server. If a
version of `project.yml` with the KLIPY key was ever pushed, rotate that key.

## 5. What this does NOT change
- Screen-share loopback port still trusts anything that connects (needs both targets redesigned).
- The local database is not SQLCipher-encrypted; message bodies are encrypted per column, metadata is not.
- Expired undelivered messages are deleted after 90 days without notifying the sender.
- Login/registration still reveal whether a username exists.
- The `Click: hyperchat://` URL scheme is registered, but I couldn't test that tapping an ntfy notification opens the app.
