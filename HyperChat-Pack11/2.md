# Pack 11 — какво да направиш

## 1. Замени / добави Swift файлове

| Файл | |
|---|---|
| `Networking/APIClientProtocol.swift` | challenge login, изтриване, push |
| `Networking/RealAPIClient.swift` | |
| `Networking/WebSocketServiceProtocol.swift` | + reconnect handler (MockWebSocketService е вътре) |
| `Networking/RealWebSocketService.swift` | |
| `Crypto/CryptoService+Signing.swift` | **нов** |
| `Services/AuthService.swift` | |
| `Services/NotePadService.swift` | часовник + опашка |
| `Services/AccountDeletionService.swift` | сега е `async` и трие и от сървъра |
| `Services/PushService.swift` | **нов** |
| `Services/AppContainer.swift` | |
| `App/AppDelegate.swift` | + APNs token |
| `Views/NotePadViewModel.swift` | |
| `Models/AttachmentPolicy.swift` | + проверка при получателя |

`MockAPIClient` не се пипа — новите методи имат default имплементации.

## 2. Ръчни промени в два файла

### ChatViewModel.swift — замени `loadMediaData`

```swift
func loadMediaData(forMessageId messageId: String) async -> Data? {
    guard let message = messagesById[messageId],
          let data = try? await messagingService.mediaData(for: message) else { return nil }
    // Проверка на устройството на получателя: блокира програми и файлове,
    // чието съдържание не отговаря на типа, с който са пратени.
    let expected = messagingService.mediaDisplayMetadata(for: message)?.mediaType
    switch AttachmentPolicy.checkReceived(data, expected: expected) {
    case .success:
        return data
    case .failure(let rejection):
        errorMessage = rejection.localizedDescription
        return nil
    }
}
```

Ако `mediaData(for:)` се вика и другаде (например при отваряне/споделяне на документ),
сложи същата проверка и там. Ако `MediaType` има повече от 4 случая
(image, video, audio, document), компилаторът ще посочи `switch`-а в
`AttachmentPolicy.checkReceived` — добави ги там.

### SettingsView.swift — замени `deleteAccount()` и добави alert

```swift
@State private var offerLocalOnlyDeletion = false

private func deleteAccount(includeServer: Bool = true) {
    guard let userId = container.authService.currentUserId else { return }
    Task {
        do {
            try await container.accountDeletionService.deleteAccount(userId: userId, includeServer: includeServer)
            container.messagingService.stopListening()
            container.presenceService.stop()
            container.alarmService.stopForLogout()
            container.profileService.deleteLocalData(ownerUserId: userId)
            container.authService.logout()
        } catch AccountDeletionError.serverUnreachable {
            offerLocalOnlyDeletion = true
        } catch {
            errorMessage = "Couldn't delete the account: \(error.localizedDescription)"
        }
    }
}

// към Form-а:
.alert("Couldn't reach the server", isPresented: $offerLocalOnlyDeletion) {
    Button("Delete from this device only", role: .destructive) { deleteAccount(includeServer: false) }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("Your account will stay on the server, and your username stays taken. Try again when you're online to remove it completely.")
}
```

## 3. Xcode: push нотификации

1. Target → **Signing & Capabilities → + Capability → Push Notifications**.
   Това добавя `aps-environment` в entitlements.
2. В Background Modes **не** е нужно „Remote notifications“ — нотификациите са видими.
3. Нужен е платен Apple Developer акаунт. В Simulator token не се издава
   (освен ако не е свързан с Mac с Apple Silicon и iOS 16+), тествай на телефон.

## 4. Apple ключ за push

developer.apple.com → Certificates, IDs & Profiles → **Keys → +** → отметка
**Apple Push Notifications service (APNs)** → свали `AuthKey_XXXXXXXXXX.p8`
(само веднъж може). Запиши Key ID и Team ID (горе вдясно в акаунта).

## 5. Сървър

Замени/добави: `src/db.js`, `src/validate.js`, `src/routes/authRoutes.js`;
нови: `src/challenge.js`, `src/apns.js`, `src/routes/accountRoutes.js`.

В `server.js`:

```js
const account = require('./src/routes/accountRoutes');
const { APNsClient, pushForEnvelope } = require('./src/apns');
const apns = APNsClient.fromEnv(); // null, ако не е настроено — всичко друго работи

router.post('/auth/login/challenge', auth.loginChallengeRoute(store, limiters)); // ако още го няма
router.post('/account/delete/challenge', account.deleteChallengeRoute(store, limiters));
router.post('/account/delete', account.deleteAccountRoute(store, limiters, presence));
router.post('/devices/push-token', account.registerPushTokenRoute(store, limiters));
router.post('/devices/push-token/remove', account.removePushTokenRoute(store));
```

В `sendMessageRoute` (`src/routes/messageRoutes.js`) — след като envelope-ът е
записан в опашката и е пробвана live доставката, добави:

```js
pushForEnvelope({ apns, store, presence, envelope: body }).catch(() => {});
```

(`apns` трябва да стигне до route-а — подай го като параметър, както `presence`.)

`.env`:
```
APNS_KEY_PATH=./keys/AuthKey_XXXXXXXXXX.p8
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=YYYYYYYYYY
APNS_TOPIC=com.hyperchat.app        # bundle id-то на приложението
```
Не качвай `.p8` файла в git.

Тест: `node test/server.test.js` → `12 server tests passed`
(ползва локален HTTP/2 сървър вместо Apple; файловете `tls.*` и `authkey.p8`
в `test/` са тестови и се генерират с openssl — виж README в test/).
