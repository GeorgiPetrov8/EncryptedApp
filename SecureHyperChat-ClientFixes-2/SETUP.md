# SecureHyperChat — клиентски поправки

Само клиент (сървърът е в пакета HyperChat-Hardening). **Нищо не е компилирано.**
Номерата са от `SecureHyperChat-ВСИЧКИ-ПРОБЛЕМИ-v2.md`.

## 1. Нови файлове (добави в таргета SecureHyperChat)

| Файл | За |
|---|---|
| `Security/SafeText.swift` | S1, S31, S32, S43 — чистене на имена/цитати, проверка на mediaId |
| `Security/ImageSafety.swift` | R22 — декодиране без декомпресионна бомба |
| `Storage/BackupExclusion.swift` | S17, S24 — извън iCloud backup; защитена tmp папка |
| `Storage/BlockListStore.swift` | S34 — блокиране |
| `App/DatabaseFailureView.swift` | R23 — екран вместо `fatalError` |
| `App/PrivacyInfo.xcprivacy` | D14 — манифест (сложи го до Info.plist) |

## 2. Замени

| Файл | Поправки |
|---|---|
| `Storage/KeychainStore.swift` | **R3** update-or-add; staging при userPresence |
| `Storage/MediaCacheStore.swift` | **S31** само UUID + проверка на пътя; **R4** без автоматично триене; S17 |
| `Storage/User.swift` | **S1** `shownName` = username; `unverifiedDisplayName` |
| `Storage/UserRepository.swift` | **S1** името само от сървъра; чист displayName |
| `Services/MediaEncryptionService.swift` | **S31** валидиран payload; **R4** logout не трие; R22 |
| `Services/MediaExporter.swift` | **S4** видео без GPS/модел/час винаги; S24 |
| `Services/ProfileService.swift` | **R22** аватарът се прекодира до 512 px; S31; S1; S17 |
| `Services/InvitationService.swift` | **S1** име от директорията; **S34** decline + block; чиста бележка |
| `Services/MessagingService.swift` | **R1** запис преди сесия + rollback; **R2** нищо при заключен ключ; **S1**; **S34**; профил само от приети; **R27** `retry(messageId:)`; S41 |
| `Services/AuthService.swift` | **R7** акаунт-сирак; **S9** expectedUserId; **R11** канонично име |
| `Services/RecoveryService.swift` | **R20**, **R21**, R24 съобщение |
| `Services/AppLockService.swift` | **S22** systemUptime; S23 `onLock` |
| `Services/NetworkConfiguration.swift` | **D8** env/mock само в DEBUG; S25 `apiSession` |
| `Views/ChatViewModel.swift` | **S32** проверени цитати; **R26**; **R27**; S4 |
| `Views/MediaMessageView.swift`, `Views/AvatarView.swift` | **R22** |
| `Views/DecryptedMediaCache.swift` | **S23** `removeAll()` |
| `Views/SettingsView.swift` | Блокирани (S34), Storage (R4), текст за ntfy (S43) |
| `App/AppContainer.swift` | R23 `tryBootstrap`; R2 backfill след отключване; S9; S23; S37 |
| `App/SecureHyperChatApp.swift` | R23 |

## 3. Ръчни редове (файлове, които не пренаписах изцяло)

**VoiceRecorder.swift** (S24) — в `start()`:
```swift
let url = ProtectedTemp.url(extension: "m4a", prefix: "voice")
```
вместо `FileManager.default.temporaryDirectory.appendingPathComponent(...)`.

**VoiceMessageViews.swift** (S41) — в `begin()`, `case .granted:` замени блока с:
```swift
do {
    try recorder.start()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
} catch {
    permissionDenied = false
    startFailed = true          // @State private var startFailed = false
}
```
и добави `.alert("Couldn't start recording", isPresented: $startFailed) { Button("OK") {} }`.
Изтрий втория `UIImpactFeedbackGenerator` и `print`.

**ChatView.swift** (S34, S1) — в банера на поканата добави
```swift
Button("Decline & block", role: .destructive) { Task { await viewModel.declineInvitation(block: true) } }
    .buttonStyle(.themedBordered)
```
а под името в хедъра (по желание):
```swift
if let alias = viewModel.peerUnverifiedName { Text("calls themselves “\(alias)”").font(.caption2) }
```

**InvitationsView.swift** — `onDecline:` → `Task { await service.decline(conversation, block: true) }` за бутон „Block“.

**RealAPIClient.swift** (S25, S31) — `session: URLSession = NetworkConfiguration.apiSession`;
в `downloadMedia(mediaId:)` първо `guard SafeIdentifier.isMediaId(mediaId) else { throw APIError.userNotFound }`.

**AccountDeletionService** — не е нужно; Settings вече вика `forgetAccount` и чисти блок-листа.

## 4. Внимание

- **S1 променя какво се вижда:** навсякъде вече излиза потребителското име, не избраното от контакта име.
- **R4:** медията вече не се трие сама. Settings → Storage показва колко място заема.
- **R2:** съобщения не се обработват, докато Face ID не отключи ключа; остават на сървъра.
- **D8:** Release build без https `API_BASE_URL` вече не работи нарочно.
- `ChallengeSigner` приех за `async throws`. Ако при теб е синхронен, махни `await` в `proveChallenge`.
