# #12 еднократно гледане + #19 опции при изпращане

Прилага се след Features3. Swift кодът не е компилиран (проверени са само скобите).
С модел проверени (14 от 14): пъзелът винаги е решим (5000 разбърквания), часовникът за
„заключено до“ не се мести при смяна на часа, датите се ограничават, събитията се
прилагат само веднъж и само към твои съобщения.

## Какво има

| Опция | Какво вижда получателят |
|---|---|
| 🎁 Подарък | „You received a gift“ → разопакова → съобщение / снимка / видео / GIF |
| 🧩 Тайно | задържане 1,5 s **или** пъзел 3×3 |
| 💨 Изчезва / виж веднъж | текст: прочита се веднъж, после изчезва и от двата телефона. Снимка/видео: само онлайн, затваря се при загуба на връзка, трие се от телефона и сървъра |
| 🔒 Заключено до | доставено веднага, закачено най-горе, четимо от датата |
| ⏰ Изпрати по-късно | нищо, докато не дойде часът |

Комбинират се (напр. подарък + заключено до рождения ден). Бутон ✨ до полето за писане;
важат за **следващото** съобщение (текст, снимка или видео) и се нулират след него.

## Нови файлове

| Файл | |
|---|---|
| `Models/SendOptions.swift` | опции + проверка + маскиран текст; `MessageEventPayload` |
| `Services/TrustedClock.swift` | време от сървъра (за „заключено до“) |
| `Services/ConsumeOnViewPolicy.swift` | общите правила за #12 и „изчезва“ |
| `Services/ViewOnceMediaLoader.swift` | сваляне само онлайн, без кеш, следене на връзката |
| `Services/ScheduledSendService.swift` | изпращане по-късно |
| `Services/OutboxService.swift` | **замени** версията от Features3 (пропуска бъдещите, `onSent`) |
| `Views/SendOptionsSheet.swift` | листът ✨ + чиповете над полето |
| `Views/RevealViews.swift` | подарък, задържане, пъзел, заключено, закачена лента, еднократен балон, „Scheduled“ |
| `Views/ConsumeOnViewViewer.swift` | преглед на цял екран |

---

## 1. Сървър
`src/validate.js` → добави `'messageEvent'` в разрешените типове.
Медия с „виж веднъж“ се качва с `X-Media-Recipients: 1` (вече е така за медия в чат от
ClientFixes) — сървърът я трие след първото сваляне. Неотворена изтича след 90 дни (вече).

## 2. DatabaseManager.swift
```swift
/// #12 #19. All nullable and local; never sent.
migrator.registerMigration("v16_send_options") { db in
    try db.alter(table: "messages") { t in
        t.add(column: "revealedAt", .datetime)    // opened (gift/secret) or first shown (once)
        t.add(column: "consumedAt", .datetime)    // once: content wiped
        t.add(column: "screenshotAt", .datetime)  // sender: they took a screenshot
        t.add(column: "scheduledFor", .datetime)  // sender: send later
    }
    try db.create(index: "idx_messages_scheduled", on: "messages", columns: ["ownerUserId", "scheduledFor"])
}
```
+ `"v16_send_options"` в `expectedMigrationIdentifiers`.

**Message.swift**: `var revealedAt: Date?`, `var consumedAt: Date?`, `var screenshotAt: Date?`, `var scheduledFor: Date?` (в ръчния `init` — `= nil`).

## 3. Payload-и
**TextPayload**: `var options: SendOptions?` (`init(... options: SendOptions? = nil)`).
**MediaKeyPayload**: `var options: SendOptions?`. `prepareForSending(..., options: SendOptions? = nil)` го записва.
**DTOs `EnvelopePayloadKind`**: `case messageEvent` — контролен (`isControlMessage` → true, `asMessageContentType` → nil).

## 4. MessagingService.swift

**Опциите на едно съобщение:**
```swift
func sendOptions(for message: Message) -> SendOptions? {
    guard !message.isUndecryptable, !message.encryptedContent.isEmpty,
          let data = try? cryptoService.decryptFromStorage(message.encryptedContent) else { return nil }
    if message.contentType == .text { return TextPayload.decode(data)?.options }
    return (try? MediaEncryptionService.decodeValidated(data))?.options
}
```
**Изпращане** — `send(plaintext:contentType:in:media:)` получава `scheduledFor: Date? = nil`:
```swift
let createdAt = scheduledFor ?? Date()
let message = Message(id: UUID().uuidString, ..., deliveryStatus: .sending, createdAt: createdAt,
                      scheduledFor: scheduledFor)
try messageRepository.insert(message, media: media)
guard state == .accepted, scheduledFor == nil else { return }   // ← scheduled: the outbox sends it when due
try await transmitStored(message, plaintext: plaintext, in: conversation)
```
`sendText(_:replyTo:options:scheduledFor:in:)` → `TextPayload(text:, replyTo:, options:)`;
`sendMedia(..., options:, scheduledFor:)` → `prepareForSending(..., options:)`.
Сървърът не трябва да вижда опциите — те са вътре в криптираното. ✔

**`flushQueuedMessages`** (при приемане на покана) — пропускай бъдещите:
```swift
.filter { $0.senderId == myUserId && $0.deliveryStatus == .sending && ($0.scheduledFor ?? .distantPast) <= Date() }
```
**Получаване** — в `storeDecrypted`, преди да запишеш съобщението, провери опциите от другия телефон:
```swift
// (TextPayload / MediaKeyPayload се декодират на същото място, където сега се проверява GIF-ът)
payload.options = payload.options?.validated(contentType: messageContentType, now: Date())
```
и запиши обратно `plaintext` с проверените опции. **„Виж веднъж“ медия не се сваля автоматично** —
`makeReceivedMediaItem` само записва реда; файлът идва чак през `ViewOnceMediaLoader`.

**`handleControlMessage`**:
```swift
case .messageEvent:
    guard let payload = try? decoder.decode(MessageEventPayload.self, from: plaintext) else { return }
    messageEventHandler?(payload, conversation, envelope.senderId)
```
(`messageEventHandler` — като `receiptHandler`, добави го в `setControlHandlers`.)

**Без изтичане на съдържанието:**
- `canEdit` и `applyRemoteEdit`: `&& sendOptions(for: message) == nil` (такива съобщения не се редактират).
- `previewText` — в началото:
```swift
if let options = sendOptions(for: message) ?? (message.consumedAt != nil ? SendOptions(consumeOnView: true) : nil),
   let masked = options.maskedPreview(contentType: message.contentType,
                                      consumed: message.consumedAt != nil,
                                      unlocked: (options.unlocksAt ?? .distantPast) <= TrustedClock.shared.now) {
    return masked
}
```
- `mediaData(for:)`: ако `sendOptions(for:)?.consumes == true` → `throw` (никога през кеша).

## 5. RealAPIClient.swift — часовник
След всеки отговор от сървъра (в общата функция за заявки):
```swift
TrustedClock.shared.record(response)
```

## 6. AppContainer.swift
```swift
let consumeOnViewPolicy: ConsumeOnViewPolicy
let viewOnceLoader: ViewOnceMediaLoader
let scheduledSendService: ScheduledSendService

self.consumeOnViewPolicy = ConsumeOnViewPolicy(dbQueue: database.dbQueue, authService: authService)
self.viewOnceLoader = ViewOnceMediaLoader(apiClient: apiClient, cryptoService: cryptoService)
self.scheduledSendService = ScheduledSendService(dbQueue: database.dbQueue, authService: authService)

consumeOnViewPolicy.configure(
    options: { [weak messagingService] in messagingService?.sendOptions(for: $0) },
    conversation: { [weak self] id in
        guard let self, let me = self.authService.currentUserId else { return nil }
        return try? self.conversationRepository.fetch(id: id, ownerUserId: me)
    },
    send: { [weak messagingService] payload, conversation in
        try await messagingService?.sendControlPayload(payload, kind: .messageEvent, in: conversation)
    }
)
// в setControlHandlers:
messageEvent: { [weak consumeOnViewPolicy] payload, conversation, senderId in
    consumeOnViewPolicy?.applyRemote(payload, from: senderId, conversation: conversation,
                                     ownerUserId: conversation.ownerUserId)
},
scheduledSendService.configure { [weak outboxService] in outboxService?.flush() }
outboxService.onSent = { [weak scheduledSendService] in scheduledSendService?.didSend(messageId: $0) }
```
При активен акаунт (след `startListening()`) и при `.active`:
```swift
self.consumeOnViewPolicy.recoverInterrupted()
self.scheduledSendService.refresh()
```
Ако `ProtectedTemp.purge()` още не се вика при старт — добави го (трие видео от прекъснат преглед).
`DecryptedMediaCache.shared.removeAll()` — ако при теб методът е с друго име, смени го в `ConsumeOnViewPolicy.wipe`.

## 7. ChatViewModel.swift
```swift
@Published var pendingOptions: SendOptions = .none
@Published var pendingScheduledFor: Date?
```
В `send()` и в изпращането на снимка/видео подай `options: pendingOptions.isEmpty ? nil : pendingOptions`,
`scheduledFor: pendingScheduledFor`; след успех → `pendingOptions = .none; pendingScheduledFor = nil`.
След отложено изпращане: `scheduledSendService.refresh()` и
`await scheduledSendService.notify(messageId:, conversationId:, peerName:, at:)`.

**`DisplayMessage`** — нови полета, попълнени в `reload()`:
```swift
let options: SendOptions?          // messagingService.sendOptions(for:)
let revealed: Bool                 // message.revealedAt != nil
let consumed: Bool                 // message.consumedAt != nil
let screenshotTaken: Bool          // message.screenshotAt != nil
let scheduledFor: Date?
var isLocked: Bool { !isMine && (options?.unlocksAt ?? .distantPast) > TrustedClock.shared.now }
```
и `text` да е **маскираният** текст (`previewText`), докато съобщението е заключено, неотворен
подарък/тайно или „веднъж“ — така не изтича в цитати при отговор, копиране и търсене.

**Закачени заключени:**
```swift
var lockedFromThem: [DisplayMessage] { messages.filter { $0.isLocked } }
```
**Отваряне на подарък/тайно:** `func markOpened(_ id: String)` → `consumeOnViewPolicy.markOpened(message)` и `reload()`.
**Отключване по време:** при `reload()` намери най-близкото `unlocksAt` в бъдещето и пусни
`Task.sleep` до него → `reload()`.

## 8. MessageBubbleView.swift — ред на проверките в `bubble`
```swift
if let options = message.options, options.consumes || message.consumed {
    ConsumeOnViewBubble(contentType: message.contentType, isMine: message.isMine,
                        consumed: message.consumed, screenshotTaken: message.screenshotTaken,
                        textColor: textColor, bubbleColor: bubbleColor, onOpen: onOpenOnce)
} else if message.isLocked, let date = message.options?.unlocksAt {
    LockedUntilView(unlocksAt: date, textColor: textColor, bubbleColor: bubbleColor)
} else if !message.isMine, message.options?.isGift == true, !message.revealed {
    GiftWrapView(textColor: textColor, bubbleColor: bubbleColor, onOpened: onOpened)
} else if !message.isMine, let reveal = message.options?.reveal, !message.revealed {
    if reveal == .puzzle {
        SlidePuzzleView(textColor: textColor, bubbleColor: bubbleColor, onOpened: onOpened)
    } else {
        HoldToRevealView(textColor: textColor, bubbleColor: bubbleColor, onOpened: onOpened)
    }
} else {
    // … съществуващото (текст, GIF, снимка, стикер, локация, карта …)
}
```
Параметри: `var onOpened: () -> Void = {}`, `var onOpenOnce: () -> Void = {}`, `var onCancelScheduled: () -> Void = {}`.
Footer: за твоите — `if let date = message.scheduledFor, message.status == .sending { ScheduledBadge(scheduledFor: date, onCancel: onCancelScheduled) }`;
за подарък/тайно — „🎁 Opened“ / „Not opened yet“ по `message.revealed`.
**Меню:** за съобщения с опции, които още не са отворени, и за всички „веднъж“ — скрий Copy, Reply,
Add to Shared Pad, Remind Me, Star, Save, Save sticker.

## 9. ChatView.swift
```swift
@State private var showSendOptions = false
@State private var onceViewer: OnceTarget?          // struct OnceTarget: Identifiable { let id: String; let message: Message; let text: String? }
```
- В `MessageInputBar` бутон ✨ (`sparkles`) → `showSendOptions = true`; над полето
  `SendOptionsChips(options: viewModel.pendingOptions, scheduledFor: viewModel.pendingScheduledFor) { showSendOptions = true }`.
- `.sheet(isPresented: $showSendOptions) { SendOptionsSheet(options: $viewModel.pendingOptions, scheduledFor: $viewModel.pendingScheduledFor) }`
- В `ForEach`: `onOpened: { viewModel.markOpened(message.id) }`,
  `onCancelScheduled: { container.scheduledSendService.cancel(messageId: message.id); viewModel.reload() }`,
  `onOpenOnce:` → вземи `Message` (`messageRepository.fetch`), за текст декриптирай с `messagingService.textContent(for:)?.text`, `onceViewer = OnceTarget(...)`.
- `.fullScreenCover(item: $onceViewer) { ConsumeOnViewViewer(message: $0.message, text: $0.text).environmentObject(container) }`
- Закачена лента в `topBar`:
```swift
if let next = viewModel.lockedFromThem.compactMap({ $0.options?.unlocksAt }).min() {
    PinnedLockedStrip(unlocksAt: next, count: viewModel.lockedFromThem.count) {
        if let first = viewModel.lockedFromThem.first { jumpTo(first.id) }
    }
    .notchStyle(chrome, cornerRadius: 16)
}
```
- `.onReceive(container.consumeOnViewPolicy.updates) { if $0 == viewModel.conversation.id { viewModel.reload() } }`

## 10. Изключване на съдържанието (важно)
- **Търсене** (`ChatSearchModel.start`): пропускай съобщения с `payload.options != nil`.
- **Галерия** (Features3): пропускай `sendOptions(for:)?.consumes == true` и `consumedAt != nil`.
- **Бекъп** (`RecoveryService.buildSnapshot`): пропускай съобщения с `consumes` (и не ги експортирай в `.hcmedia`).
- **Стикери/звезда/запазване:** не за „веднъж“.
- **ntfy**: без промяна — и сега праща само общ текст.

## 11. AccountDeletionService.swift
```swift
ScheduledSendService.removeAll(ownerUserId: userId)
```

---

## Решения, които взех

- **„Изпрати по-късно“ е на телефона, не на сървъра.** Ако сървърът държи криптирано съобщение дни наред, ключът му в получателя се изхвърля след две „завъртания“ на криптирането и съобщението пристига нечетимо. Цената: ако приложението е затворено в този час, излиза известие и се праща при отваряне.
- **„Виж веднъж“ се брои за видяно при първия кадър.** Изключване на интернета или затваряне не дава втори поглед. Ако не се отвори (няма интернет), не се губи.
- **„Изчезва след прочитане“ изчезва и от двата телефона.**
- **„Заключено до“ ползва времето на сървъра**, не на телефона — смяна на часа не го отваря. След рестарт на телефона трябва веднъж връзка със сървъра; дотогава важи часът на телефона.
- **Скрийншотът не може да се спре на iOS** — само се съобщава на изпращача. При запис на екрана съдържанието се скрива.
- **Всичко се спазва от приложението на получателя.** По-стара версия показва съобщението направо; променено приложение може да заобиколи всичко. Сървърът никога не вижда опциите.
