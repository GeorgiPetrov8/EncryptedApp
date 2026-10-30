# Pack 4 — нови функции + поправки

Прилага се **след** SessionRenewal, ClientFixes, ServerFixes, Fixes3 и Protocol2.
Swift кодът не е компилиран; сървърните файлове минават `node --check`.

## Какво има

| # | Какво | Файлове |
|---|---|---|
| 1 | Бутон „надолу“ (с брой нови), скрива се най-долу | `ChatView` |
| 2 | Автоматично свързване: при отваряне, при връщане на мрежата, на 15 s ако няма връзка | `ConnectionMonitor` (нов), `RealWebSocketService`, `SecureHyperChatApp`, `ConversationListView`, `SettingsView` |
| 3 | Съобщенията винаги показват затворен катинар („encrypted“) | ръчно в `MessageBubbleView` (виж долу) |
| 4 | Линия „N unread messages“ + отваряне там | `ChatViewModel`, `ChatView` |
| — | Аларма: само приети контакти | `AlarmEditView` + ръчно в `AlarmService` |
| P4 | Една защита на файловете | `Resources/SecureHyperChat.entitlements` |
| S34 | Изтриване на чат (плъзгане / задържане) | `ConversationDeletionService` (нов), `ConversationListView(Model)` |
| S35 | Фонове по акаунт, трият се с акаунта | `AppearanceStore` |
| S26 | HEIC/AVIF/MOV, polyglot, PDF `/Launch`, Office макроси | `AttachmentPolicy` |
| S42 | GIF: само https, без кеш/бисквитки, лимит на декодираното | `GIFLoader` (нов файл) |
| S43 | Верни текстове при вход | `LoginView` (+ ръчно в `RecoverySettingsView`) |
| APNs | Махнат напълно | `AppDelegate`, `AppContainer`; сървър `server.js`, `messageRoutes.js`, `accountRoutes.js` |
| N+1 | Списъкът с чатове: обединени презареждания, кеш на прегледа | `ConversationListViewModel` |
| #9 | Не те дърпа надолу, ако четеш назад; лимит 4000 знака; чернови | `ChatView`, `ChatViewModel`, `DraftStore` (нов) |
| R8 | Няколко акаунта на един телефон + превключване | `SessionTokenStore`, `AuthService`, `LoginView`, `SettingsView` |

## 1. Нови файлове
`Services/ConnectionMonitor.swift`, `Services/DraftStore.swift`,
`Services/ConversationDeletionService.swift`, `Views/GIFLoader.swift`.

## 2. Изтрий
- `PushService.swift` (клиент), `src/apns.js` (сървър).
- В `MediaViews.swift` изтрий целия `final class GIFLoader { … }` (вече е в `GIFLoader.swift`).
- `.env`: редовете `APNS_*`.
- (по желание) `registerPushToken` / `removePushToken` от `APIClientProtocol`, `RealAPIClient`, `MockAPIClient`.

## 3. Замени
Всички останали файлове от пакета. `Resources/SecureHyperChat.entitlements` → на мястото на
`SecureHyperChat/Resources/SecureHyperChat.entitlements`.

## 4. Ръчни редакции

**MessageBubbleView.swift (#3)** — замени двете свойства в края:
```swift
private var lockIcon: String {
    message.status == .undecryptable ? "lock.trianglebadge.exclamationmark" : "lock.fill"
}

private var lockAccessibilityLabel: String {
    if message.status == .undecryptable { return "Encrypted, could not be decrypted" }
    return peerIsVerified ? "End-to-end encrypted, identity verified" : "End-to-end encrypted"
}
```
Всяко съобщение е криптирано — катинарът вече го казва винаги. Сравнението на safety
number (Verify security) остава **по избор**: то доказва, че няма човек по средата, и се
показва като щит до името. Автоматично „verified“ не правя — тогава щитът не би значел нищо.

**AlarmService.swift** — в `makeChallenge`, `case .messageContact:` замени guard-а с:
```swift
guard let peerId = alarm.accountabilityPeerId,
      let peer = try? userRepository.fetch(ownerUserId: alarm.ownerUserId, id: peerId),
      let chat = try? conversationRepository.findDirectConversation(
          ownerUserId: alarm.ownerUserId, userA: alarm.ownerUserId, userB: peerId),
      chat.relationshipState == .accepted
else {
    fallbackNotice = "The contact for this alarm hasn't accepted your chat, so it's asking for problems instead."
    return .tasks(completed: 0, required: max(1, alarm.requiredTaskCount), task: .random())
}
```
И там, където AlarmService взима разговора за изпращане на думата (търси `Conversation(`
в файла): **не създавай** нов разговор — само `findDirectConversation`, а ако е `nil` или
не е `.accepted` → `throw InvitationError.notAccepted`.

**RecoverySettingsView.swift (S43)** — в footer-а на „Server backup“ смени
`"Stored encrypted with your password — the server can't read it."` с
`"Stored encrypted with your password. The server can't read it — as long as the password is hard to guess."`

## 5. Как работят новите неща

- **Няколко акаунта:** Settings → *Accounts on this phone*. Превключването не излиза от
  сървъра: другият акаунт остава влязъл и **продължава да получава ntfy известия**. „Add
  another account“ води до входа; там акаунтите на телефона се избират с едно докосване.
  Стар единичен токен се прехвърля автоматично към текущия акаунт.
- **Фонове:** старите (общи) настройки се дават на първия акаунт, който влезе.
- **Линия за непрочетени:** при отваряне на чат или връщане в приложението; изчезва, когато
  отговориш или излезеш от чата. Ако непрочетените са много, зарежда до 1000 назад.
- **Изтриване на чат:** само на този телефон; другият не разбира. Ако ти пише отново,
  идва като нова покана.

## 6. Внимание
- `setLogoutHandler` вече е `(userId, keepServerSession)`. Ако някъде другаде го викаш — смени.
- `ConversationSummary` е дефиниран в `ConversationListViewModel.swift` — ако го имаш и другаде, изтрий дубликата.
- `Message.readAt` трябва да е `var` (така е от ClientFixes).
- Entitlement-ът сменя защитата само на **нови** файлове.
