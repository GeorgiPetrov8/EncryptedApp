# Протокол v2 (S7, S8, S40) + страниране (R25) + бекъп на медията (R4)

Нищо от Swift кода не е компилирано. Прилага се **след** SessionRenewal, ClientFixes,
ServerFixes и Fixes3. Сървърът **не се променя** (версията пътува вътре в криптираното
`ratchetMessage`, което сървърът не чете).

## 1. Файлове

| Файл | Нов / замени | Какво |
|---|---|---|
| `Crypto/ProtocolV2.swift` | **нов** | версия, контексти за подписи, `MessageContext`, `HandshakeReplayGuard` |
| `Crypto/DoubleRatchet.swift` | замени | **S7** AAD v2 (идентичности + id, разговор, подател, получател, тип); версия в съобщението; защита от понижаване; **R9** 90 дни |
| `Crypto/X3DH.swift` | замени | **S8** проверка на подписа на signed prekey с етикет; associated data |
| `Crypto/IdentityKeyPair.swift` | замени | **S8** нов подпис `"SHC-spk-v1" ‖ key`; `CryptoError.protocolMismatch` |
| `Services/MessagingService.swift` | замени | v2 сесии; **S40** стар handshake се отхвърля; **R1** one-time ключ се трие след запис; еднократно изтриване на v1 сесиите |
| `Storage/MessageRepository.swift` | замени | **R25** `fetchRecentMessages`, `countMessages`, реакции по страница; `fetchMediaMessages` |
| `Views/ChatViewModel.swift` | замени | **R25** зарежда последните 100, „още 100“ при скрол нагоре; кеш на декриптираното |
| `Services/MediaBackupFile.swift` | **нов** | **R4** формат `.hcmedia`, запис/четене по един файл |
| `Services/RecoveryService.swift` | замени | **R4** експорт/импорт на медия, медийни редове при restore; 95 MB; подписи от ServerFixes |

Ръчните редакции от Fixes3 за `DoubleRatchet` (R9) и `MessagingService` (R1) **вече са вътре** — не ги прави отделно.

## 2. Ръчни редакции

### CryptoService.swift (задължително — иначе не се компилира / не работи)

**a) one-time ключ без триене (R1)** — замени `consumeOneTimePreKey` с:
```swift
func oneTimePreKey(id: UInt32) throws -> Curve25519.KeyAgreement.PrivateKey? {
    let name = try account(Keys.oneTimePreKeysPrefix + String(id))
    guard let data = keychain.loadIfPresent(key: name) else { return nil }
    return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
}

func deleteOneTimePreKey(id: UInt32) {
    guard let name = try? account(Keys.oneTimePreKeysPrefix + String(id)) else { return }
    keychain.delete(key: name)
    try? saveLiveOneTimePreKeyIds(loadLiveOneTimePreKeyIds().filter { $0 != id })
}
```

**b) подмяна на стария signed prekey (S8)** — в `rotateSignedPreKeyIfNeeded()`:
```swift
let hasLegacy = identity.map { current.hasLegacySignature(identity: $0) } ?? false
guard current.needsRotation || hasLegacy else {
    signedPreKey = current
    try pruneExpiredSignedPreKeys()
    return nil
}
```
(Новият ключ се публикува от `MessagingService` при старт.)

**c) импорт от бекъп (S8)** — в `importKeyMaterial` замени проверката с:
```swift
guard SignedPreKey.isValidSignature(
    entry.signature,
    for: privateKey.publicKey.rawRepresentation,
    signedBy: identity.signingPublicKey,
    allowLegacy: true          // стари бекъпи
) else { throw CryptoError.invalidSignature }
```

**d) подпис на challenge (S8)** — ако не е направено от Fixes3:
```swift
func signChallenge(_ challenge: LoginChallenge, expectedUserId: String? = nil) throws -> Data {
    if let expectedUserId, challenge.userId != expectedUserId { throw AuthError.userIdMismatch }
    guard let nonce = Data(base64Encoded: challenge.nonce) else { throw CryptoError.invalidKeyData }
    guard let identity else { throw CryptoError.noActiveAccount }
    return try identity.signingPrivateKey.signature(for: ProtocolV2.challengeContext + nonce)
}
```

### ChatView.swift — страниране
В `messageList`, вътре в `LazyVStack`, **преди** `ForEach`:
```swift
if viewModel.hasOlder {
    ProgressView()
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear {
            let anchor = viewModel.messages.first?.id
            viewModel.loadOlder()
            if let anchor {
                DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
}
```
и замени
```swift
.onChange(of: viewModel.messages.count) { _, _ in
```
с
```swift
.onChange(of: viewModel.messages.last?.id) { _, _ in
```
(иначе зареждането на по-стари съобщения скача до дъното).

### RecoverySettingsView.swift — бекъп на медията
Горе:
```swift
@State private var mediaFile: URL?
@State private var showMediaImporter = false
```
В `fileBackupSection`, след бутона „Export backup file“:
```swift
Button {
    perform { mediaFile = try await service.exportMediaBackupFile() }
} label: {
    Label("Export photos & videos", systemImage: "photo.stack")
}
if let mediaFile {
    ShareLink(item: mediaFile) {
        Label("Save or share \(mediaFile.lastPathComponent)", systemImage: "folder")
    }
}
Button {
    showMediaImporter = true
} label: {
    Label("Import photos & videos", systemImage: "square.and.arrow.down")
}
if let progress = service.mediaProgress {
    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
}
```
и на `Form`:
```swift
.fileImporter(isPresented: $showMediaImporter, allowedContentTypes: [.data, .item]) { result in
    guard case .success(let url) = result else { return }
    perform {
        let added = try await service.importMediaBackupFile(from: url)
        message = "\(added) attachments restored."
    }
}
```
Footer на секцията — добави: „Photos and videos are a separate file (.hcmedia). Keep both files.“

## 3. Как се пуска (важно)

1. Сървърът: остави `LEGACY_CHALLENGE_SIGNATURES=1` и `SPK_SIGNATURE_CHECK=warn`.
2. Инсталирай новата версия на **всички** телефони.
3. При първо отваряне всеки телефон: прочита чакащите съобщения със старите сесии, после
   изтрива v1 сесиите и подменя signed prekey-я си. Първото съобщение след това създава нова v2 сесия.
   Историята остава — губи се само старото криптографско състояние.
4. Когато всички са обновени:
   - `ProtocolV2.acceptLegacy = false` (в `ProtocolV2.swift`) и нова версия;
   - сървър: `LEGACY_CHALLENGE_SIGNATURES=0`, `SPK_SIGNATURE_CHECK=enforce`.

**Докато някой телефон е на старата версия:** той не може да чете съобщения от обновен
телефон в нова сесия (показва „couldn't be decrypted“) — затова „всички наведнъж“.

## 4. Ограничения
- `createdAt` нарочно не е в AAD — сървърът подрязва часа от телефони с избързал часовник.
- `.hcmedia` не е с отделна парола: файловете в него са вече криптирани с ключове, които
  са само в паролирания `.hcbackup`. Издава броя и размера на прикачените файлове.
- Страниране само в чата; списъкът с разговори още декриптира последното съобщение на всеки (N+1).
