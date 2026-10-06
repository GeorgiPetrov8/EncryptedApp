# Pack 12 — какво да направиш

## 1. Замени / добави Swift файлове

| Файл | Ново? | За точка |
|---|---|---|
| `Models/MessagePayloads.swift` | замени | 7, 9 |
| `Models/MessageReaction.swift` | **нов** | 7 |
| `Models/DTOs.swift` | замени | 7 |
| `Persistence/DatabaseManager.swift` | замени (+ миграция v11) | 7 |
| `Persistence/MessageRepository.swift` | замени | 7 |
| `Services/MessagingService.swift` | замени | 7, 9 |
| `Services/MediaEncryptionService.swift` | замени | 2 |
| `Services/MediaExporter.swift` | **нов** | 2, 8 |
| `Services/VoiceRecorder.swift` | замени | 4 |
| `Services/TenorService.swift` | замени (сега KLIPY/GIPHY) | 9 |
| `Services/CallService.swift` | замени | 3 |
| `Services/ScreenShareReceiver.swift` | **нов** | 3 |
| `Shared/ScreenShareWire.swift` | **нов — в ДВАТА таргета** | 3 |
| `Views/AppScreenStyle.swift` | **нов** | 1 |
| `Views/ConversationListView.swift` | замени | 1 |
| `Views/SettingsView.swift` | замени | 1, 6, 9 |
| `Views/InvitationsView.swift` | замени | 1 |
| `Views/AttachmentMenu.swift` | замени | 2 |
| `Views/ChatView.swift` | замени | 1, 2, 7, 8 |
| `Views/ChatViewModel.swift` | замени | 2, 7, 8, 9 |
| `Views/MessageBubbleView.swift` | замени | 5, 7, 8 |
| `Views/MediaViews.swift` | **нов** | 2, 7, 8, 9 |
| `Views/VoiceMessageViews.swift` | замени | 4 |
| `Views/GIFPickerView.swift` | замени | 9 |
| `Views/ScreenShareButton.swift` | **нов** | 3 |

`AppContainer` и `AccountDeletionService` не се променят.

## 2. Ръчни промени (по 1 ред)

**RecoverySettingsView.swift**, **NotificationSettingsView.swift**, **AlarmListView.swift** — след `.navigationTitle(...)` добави:
```swift
.appScreenStyle()
```

**CallView.swift** — замени бутона за споделяне на екрана:
```swift
controlButton(
    icon: "rectangle.inset.filled.on.rectangle",
    active: service.isScreenSharing
) { Task { await service.toggleScreenShare() } }
.accessibilityLabel(service.isScreenSharing ? "Stop sharing screen" : "Share screen")
```
с:
```swift
ScreenShareButton(service: service)
```

## 3. Info.plist (Target → Info)

| Ключ | Стойност |
|---|---|
| Privacy - Photo Library **Additions** Usage Description | `HyperChat saves photos and videos you choose to your library.` |
| `GIF_API_KEY` (String) | ключът ти от KLIPY |
| `GIF_API_HOST` (String, по избор) | `api.klipy.com` (по подразбиране) или `api.giphy.com` |

Без първия ключ iOS спира приложението при първото „Save Image“.

## 4. GIF ключ (KLIPY, безплатно)

1. partner.klipy.com → регистрация → **API Keys → Add Platform** → копирай ключа.
2. Сложи го в `GIF_API_KEY`.
3. Тестовият ключ е до 100 заявки на час. За повече: „Request production access“ от същия панел.

## 5. Разширение за споделяне на екрана (Xcode)

1. **File → New → Target → Broadcast Upload Extension**.
   Име: `HyperChatScreenShare` (точно така). Махни отметката **Include UI Extension**.
2. Bundle Identifier трябва да е `<bundle id на приложението>.HyperChatScreenShare`,
   например `com.HyperChat.app.HyperChatScreenShare`.
3. Deployment target на разширението: iOS 17.
4. Замени генерирания `SampleHandler.swift` с `ScreenShareExtension/SampleHandler.swift`.
5. `Shared/ScreenShareWire.swift` → File Inspector → **Target Membership**: отметни и
   **HyperChat**, и **HyperChatScreenShare**.
6. App Group **не е нужна**.

(Ако ползваш xcodegen, в `project.yml` в пакета таргетът вече е описан.)

**SideStore:** разширението е отделен App ID. При инсталация избери да **запазиш**
разширенията (не „Remove extensions“). С безплатен акаунт то се брои към лимита
от 10 App ID на седмица.

**Как се ползва:** само във **видео** разговор. Бутонът отваря системния прозорец →
„Start Broadcast“. Камерата спира и другият вижда екрана ти; при спиране камерата се връща.

## 6. Сървър

Замени `src/validate.js` с `Server/validate.js` (добавен е `'reaction'`) и рестартирай.
Без това реакциите връщат 400.
