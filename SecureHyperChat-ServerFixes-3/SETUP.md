# Сървърни поправки (SecureHyperChat)

**Пуснато:** 41 проверки срещу този код (Node 24, in-memory база) — всички минават.
Непроменените файлове (`router.js`, `ws.js`, `apns.js`, `mailer.js`, `envelopeMapper.js`,
`routes/ntfyRoutes.js`) бяха заместени при теста с еквивалентни копия.

## 1. Файлове

| Файл | Нов/замени | Поправки |
|---|---|---|
| `server.js` | замени | `/recovery/cancel`; лимит на неавтентикирани WebSocket-и; HTTP timeouts; предупреждения при старт |
| `src/secret.js` | **нов** | общ сървърен секрет |
| `src/json.js` | замени | R13 `Cache-Control: no-store`, `nosniff`; `sendNoContent` |
| `src/rateLimit.js` | замени | **S6** `TRUST_PROXY=cloudflare`; отделни кофи; лимит по акаунт за влезли |
| `src/challenge.js` | замени | **S8** (сървърна половина) префикс `SHC-challenge-v1`; **S21** decoy challenge |
| `src/validate.js` | замени | **S14** проверка на подписа на signed prekey; **S1** истинско `senderUsername`; дублирани OTK id |
| `src/db.js` | замени | **R15** `user_version`=2; `ntfy_topics`, `recovery_holds`, броене на изтегляния, `last_used_at`, `requester` |
| `src/auth.js` | замени | `last_used_at` на сесиите |
| `src/ntfy.js` | замени | таблицата е в db.js; `NTFY_GENERIC`; `notifyUser` |
| `src/presence.js` | замени | контакти само при реална покана (S15); `notify` |
| `src/routes/authRoutes.js` | замени | собствена кофа за регистрация; decoy при вход |
| `src/routes/prekeyRoutes.js` | замени | S14 при ротация |
| `src/routes/messageRoutes.js` | замени | **S15** само покани от непознати; **S1** |
| `src/routes/mediaRoutes.js` | замени | **S16** изтриване след доставка (`X-Media-Recipients`) |
| `src/routes/recoveryRoutes.js` | замени | **S2** изчакване + отказ; **S10** подпис; **S11** кодовете не се „горят“ |
| `src/routes/accountRoutes.js` | замени | `sendNoContent` |
| `.env.example` | замени | нови настройки |

Базата се мигрира сама при старт (v1 → v2), данните остават. Тествано и с база без версия.

## 2. `.env`

```
TRUST_PROXY=cloudflare          # само с Cloudflare Tunnel!
RECOVERY_HOLD_HOURS=24
SPK_SIGNATURE_CHECK=warn        # → enforce след проверка (виж 4)
LEGACY_CHALLENGE_SIGNATURES=1   # → 0 след като клиентът е обновен
ALLOW_UNSIGNED_EMAIL_CHANGE=1   # временно, докато не обновиш клиента (стъпка 3)
```

## 3. Клиент (задължително, иначе Settings → Recovery дава „proofRequired“)

1. Замени `RecoveryAPI.swift` с `Client/RecoveryAPI.swift`.
2. В `RecoveryService.swift`:
```swift
func removeEmail() async throws {
    try await api.removeEmail(prove: proveChallenge)
    await refreshEmailStatus()
}
func deleteServerBackup() async throws {
    try await api.deleteBackup(prove: proveChallenge)
    await refreshEmailStatus()
}
func cancelRecovery() async throws {
    try await api.cancelRecovery()
    await refreshEmailStatus()
}
```
3. **S8** — в `CryptoService` (`signChallenge`) подписвай с префикс:
```swift
return try signWithIdentity(Data("SHC-challenge-v1".utf8) + nonce)
```
След като всички телефони са обновени → `LEGACY_CHALLENGE_SIGNATURES=0`.
4. **S16** — в `RealAPIClient.uploadMedia(data:)` добави за медия в съобщения:
```swift
request.setValue("1", forHTTPHeaderField: "X-Media-Recipients")
```
(аватарите — без хедъра; те се теглят от много хора.) Без това файловете остават до 90 дни, както досега.
5. **S2** (по желание) — в `RecoverySettingsView` при `status.recoveryPending != nil` покажи
предупреждение и бутон „Cancel recovery“ → `recoveryService.cancelRecovery()`.

## 4. Как да включиш `SPK_SIGNATURE_CHECK=enforce`
Регистрирай акаунт от реалното приложение с `warn`. Ако в лога **няма**
`signed prekey signature did not verify` → смени на `enforce`. Ако има — приложението
подписва в друг формат; кажи ми и ще го нагодя.

## 5. Какво се промени за потребителя
- Непознат може да прати само покана. Съобщения, обаждания и профил — след покана.
- Възстановяване **с нови ключове** при активно устройство чака 24 ч. (с известие и отказ).
  Възстановяване от бекъп + парола — без промяна.
- Кодовете за възстановяване не могат да бъдат „изгорени“ от чужд човек.

## 6. Не е направено
- S8 напълно (подписът на prekey с префикс — клиент + миграция на ключове).
- S7/S40 (AAD/replay) — протокол, клиент.
- R11 известие за изтекли недоставени съобщения (сървърът не може да прати криптирано).
- S29 метаданни — по дизайн (`NTFY_GENERIC=1` и собствен ntfy намаляват).
- Медия/бекъпи като BLOB в SQLite (за албумите — файлове на диска).
