# Пакет 3 — оставащите поправки (без проверка за сила на паролата)

Нищо от Swift кода не е компилирано. Прилага се **след** SessionRenewal, ClientFixes и ServerFixes.

## 1. Замени / добави

| Файл | Поправки |
|---|---|
| `Client/RealWebSocketService.swift` | **R6** кодове 4000/4001/4003 (две устройства вече не се изритват всяка секунда); 401 по WebSocket → подновяване на сесията; известие за започнато възстановяване |
| `Client/AppContainer.swift` | SessionRenewal вграден; **без Apple push** (не се иска разрешение, не се качва токен); поправен `proveChallenge` (беше `await` в синхронна функция — грешка при компилация) |
| `Client/NtfyService.swift` | **S36** темата в Keychain (мигрира от UserDefaults); копиране само локално, изтича след 2 мин |
| `Client/ReceiptService.swift` | **S38** потвърждения само за твои съобщения в същия разговор, до 500 id |
| `Client/AlarmScheduler.swift` | **S37** трие само своите известия; **F10** звук `alarm.wav` |
| `Client/RegisterView.swift` | **S43** верен текст |
| `Resources/alarm.wav` | **F10** 25 s звук (добави в таргета, *Copy Bundle Resources*) |

`AppDelegate` и `PushService` остават само за да се компилира. `SessionRenewal/SETUP.md` стъпка 5 (RealWebSocketService) вече е в новия файл; стъпки 3 и 4 (scenePhase, `RealAPIClient`) остават.

## 2. Ръчни редакции

**CryptoService.swift — R1 (one-time ключът да не се трие преди успех)**
Замени `consumeOneTimePreKey` с:
```swift
/// Reads a one-time prekey WITHOUT deleting it (R1).
func oneTimePreKey(id: UInt32) throws -> Curve25519.KeyAgreement.PrivateKey? {
    let name = try account(Keys.oneTimePreKeysPrefix + String(id))
    guard let data = keychain.loadIfPresent(key: name) else { return nil }
    return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
}

/// Deletes it once the message that used it is safely stored.
func deleteOneTimePreKey(id: UInt32) {
    guard let name = try? account(Keys.oneTimePreKeysPrefix + String(id)) else { return }
    keychain.delete(key: name)
    try? saveLiveOneTimePreKeyIds(loadLiveOneTimePreKeyIds().filter { $0 != id })
}
```

**CryptoService.swift — S8 + F7** (замени двете функции в `extension CryptoService`):
```swift
func signWithIdentity(_ message: Data) throws -> Data {
    guard let identity else { throw CryptoError.noActiveAccount }
    return try identity.signingPrivateKey.signature(for: message)
}

func signChallenge(_ challenge: LoginChallenge, expectedUserId: String? = nil) throws -> Data {
    if let expectedUserId, challenge.userId != expectedUserId { throw AuthError.userIdMismatch }
    guard let nonce = Data(base64Encoded: challenge.nonce) else { throw CryptoError.invalidKeyData }
    return try signWithIdentity(Data("SHC-challenge-v1".utf8) + nonce)
}
```
⚠️ Работи само със сървъра от ServerFixes. След като всички телефони са обновени → `LEGACY_CHALLENGE_SIGNATURES=0`.

**MessagingService.swift (ClientFixes версията) — R1**
В `respondToHandshake`:
```swift
let myOneTimePreKey = try handshake.usedOneTimePreKeyId.flatMap {
    try cryptoService.oneTimePreKey(id: $0)
}
```
В `handleIncoming`, след `pendingHandshakes.clear(...)`:
```swift
if let id = envelope.handshake?.usedOneTimePreKeyId {
    cryptoService.deleteOneTimePreKey(id: id)
}
```

**DoubleRatchet.swift — R9**
```swift
private static let skippedKeyTTL: TimeInterval = 90 * 24 * 60 * 60 // = server retention
```

**CallService.swift — R12** — където се добавя в `pendingRemoteCandidates`:
```swift
guard pendingRemoteCandidates.count < 64 else { return }
pendingRemoteCandidates.append(candidate)
```

**PendingHandshakeStore.swift — S41** — `\(peerId, privacy: .public)` → `\(peerId, privacy: .private)`.
Същото навсякъде, където `.public` е до `userId`, `peerId`, `envelope.id` (Find in project: `privacy: .public`).

**SettingsView.swift (ClientFixes)** — в `deleteAccount` след `blockList.removeAll`:
```swift
container.ntfyService.deleteLocalData(ownerUserId: userId)
```

**Лимит на бекъпа → 95 MB**
- сървър `src/routes/recoveryRoutes.js`: `const MAX_BACKUP_BYTES = 95 * 1024 * 1024;` и текстът `'Backup is larger than 95 MB.'`
- клиент `RecoveryService.swift`: `static let maxServerBackupBytes = 95 * 1024 * 1024`
  и текстът на `backupTooLarge` → „95 MB“.
- Над ~100 MB заявката спира Cloudflare (безплатен план) — затова 95, не повече.

## 3. Не е направено тук

- Проверка за сила на паролата на бекъпа (S18/S19) — по твое решение.
- S7/S40 (AAD, стар handshake), S8 за signed prekey — протокол, отделно и наведнъж.
- S34 изтриване на разговор, S35 фонове по акаунт, R8 токен по акаунт, S26/S42, R13 — трябват файлове, които не съм пренаписал (ConversationListView/ViewModel, AppearanceStore, SessionTokenStore, AttachmentPolicy, GIFLoader).
- Големите: R4 бекъп на медия, R16, R24, R25, S33.
