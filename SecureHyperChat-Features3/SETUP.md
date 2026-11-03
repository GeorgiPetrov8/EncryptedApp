# Функции: 1 звезда + галерия, 7 стикери, 10 автоматично изпращане, 11 заключване на чат

Прилага се след Features2. **Сървърът не се променя.** Swift кодът не е компилиран
(проверени са само скобите). Правилата на опашката (#10) са проверени с модел — 8 от 8
случая минават (кое се праща, backoff, офлайн, „в процес“, отказ след 72 ч).

## Нови файлове

| Файл | |
|---|---|
| `Services/OutboxService.swift` | #10 |
| `Services/ChatLockService.swift` | #11 + `chatLockGate` (покритие при фон) |
| `Services/StickerService.swift` | #7 правене (изрязване на обекта на телефона) + колекция |
| `Views/StickerViews.swift` | #7 избор, създаване, стикер в чата |
| `Views/ChatMediaGalleryView.swift` | #1 снимки и видеа, файлове и глас, отбелязани |

Ползват `ImageSafety`, `ProtectedTemp`, `BackupExclusion` (ClientFixes), `ThemedSection`,
`ThemedEmptyState`, `StatusText`, `.appScreenStyle()` (Pack15).

---

## 1. DatabaseManager.swift — миграция

След `v14_challenges_occasions`:
```swift
/// #1 star (local only), #11 chat lock (local only).
migrator.registerMigration("v15_star_lock") { db in
    try db.alter(table: "messages") { t in
        t.add(column: "isStarred", .boolean).notNull().defaults(to: false)
    }
    try db.create(index: "idx_messages_starred", on: "messages",
                  columns: ["ownerUserId", "conversationId", "isStarred"])
    try db.alter(table: "conversations") { t in
        t.add(column: "isLocked", .boolean).notNull().defaults(to: false)
    }
}
```
и `"v15_star_lock"` в `expectedMigrationIdentifiers`.

## 2. Модели

**Message.swift**: `var isStarred: Bool = false` (в ръчния `init` — параметър със стойност по подразбиране).
**Conversation.swift**: `var isLocked: Bool = false` (същото).

**MediaKeyPayload** (в `MediaEncryptionService.swift`) — #7:
```swift
/// #7: draw without a bubble. Optional: older versions show it as a photo.
var sticker: Bool?
```
`prepareForSending(...)` получава параметър `isSticker: Bool = false` и го слага в payload-а
(`sticker: isSticker ? true : nil`). В `decodeValidated` нищо не се проверява допълнително —
стикерът минава през същите проверки като снимка.

**MediaDisplayMetadata** (в `MessagingService.swift`):
```swift
let isSticker: Bool
```
в `mediaDisplayMetadata(for:)`: `isSticker: payload.sticker == true && payload.mediaType == .image`.

## 3. MessageRepository.swift

```swift
// #1
func setStarred(messageId: String, ownerUserId: String, isStarred: Bool) throws {
    try dbQueue.write { db in
        guard var message = try Message.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId)) else { return }
        message.isStarred = isStarred
        try message.update(db)
    }
}

func fetchStarred(conversationId: String, ownerUserId: String) throws -> [Message] {
    try dbQueue.read { db in
        try Message
            .filter(Column("ownerUserId") == ownerUserId)
            .filter(Column("conversationId") == conversationId)
            .filter(Column("isStarred") == true)
            .order(Column("createdAt").desc)
            .fetchAll(db)
    }
}

func fetchMediaMessages(conversationId: String, ownerUserId: String) throws -> [Message] {
    try dbQueue.read { db in
        try Message
            .filter(Column("ownerUserId") == ownerUserId)
            .filter(Column("conversationId") == conversationId)
            .filter(Column("contentType") != MessageContentType.text.rawValue)
            .order(Column("createdAt").desc)
            .fetchAll(db)
    }
}

// #10: own messages not yet sent.
func fetchUnsent(ownerUserId: String) throws -> [Message] {
    try dbQueue.read { db in
        try Message
            .filter(Column("ownerUserId") == ownerUserId)
            .filter(Column("senderId") == ownerUserId)
            .filter(Column("deliveryStatus") == DeliveryStatus.sending.rawValue)
            .order(Column("createdAt").asc)
            .limit(500)
            .fetchAll(db)
    }
}
```
(Ако `DeliveryStatus` не е `String` raw value, филтрирай в Swift след `fetchAll`.)

**ConversationRepository.swift** — #11:
```swift
func setLocked(conversationId: String, ownerUserId: String, isLocked: Bool) throws {
    try dbQueue.write { db in
        guard var conversation = try Conversation.fetchOne(db, key: ["ownerUserId": ownerUserId, "id": conversationId]) else { return }
        conversation.isLocked = isLocked
        try conversation.update(db)
    }
}
```

## 4. MessagingService.swift

**#10 — „в процес“ и временни грешки.** Свойство и метод:
```swift
private var inFlight = Set<String>()
func isInFlight(_ messageId: String) -> Bool { inFlight.contains(messageId) }
/// Set by AppContainer: wakes the outbox after a temporary failure.
var onTransientFailure: (() -> Void)?
```
В `transmitStored` замени тялото с:
```swift
guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }
inFlight.insert(message.id)
defer { inFlight.remove(message.id) }
do {
    try await transmitEnvelope(id: message.id, plaintext: plaintext,
                               contentType: message.contentType.asEnvelopePayloadKind,
                               in: conversation, createdAt: message.createdAt)
    try messageRepository.updateDeliveryStatus(messageId: message.id, ownerUserId: myUserId, status: .sent)
} catch {
    // #10: temporary → stays "waiting" (clock) and the outbox retries it.
    let transient = OutboxService.isTransient(error)
    try? messageRepository.updateDeliveryStatus(messageId: message.id, ownerUserId: myUserId,
                                                status: transient ? .sending : .failed)
    if transient { onTransientFailure?() }
    throw error
}
```
В `retry(messageId:in:)` разреши и `.sending` (вече е разрешено в Protocol2) и пропусни, ако `inFlight.contains(messageId)`.

**#1 / #7:**
```swift
/// Gallery: nil instead of throwing (expired on server, not downloadable…).
func mediaDataOrNil(for message: Message) async -> Data? {
    try? await mediaData(for: message)
}

/// #7
func sendSticker(_ png: Data, in conversation: Conversation) async throws {
    guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
    try requireCanCompose(in: conversation)
    let prepared = try await mediaEncryptionService.prepareForSending(
        rawData: png, thumbnail: nil, mediaType: .image, ownerUserId: me, isSticker: true)
    try await send(plaintext: prepared.messagePayload, contentType: .image,
                   in: conversation, media: prepared.pendingMediaItem)
}
```
`previewText` за `.image`: `return mediaDisplayMetadata(for: message)?.isSticker == true ? "🌟 Sticker" : "📷 Photo"`.

## 5. AppContainer.swift

```swift
let outboxService: OutboxService
let chatLockService = ChatLockService()
let stickerService: StickerService

// init, след messagingService:
self.stickerService = StickerService(authService: authService)
self.outboxService = OutboxService(messageRepository: messageRepository,
                                   conversationRepository: conversationRepository,
                                   messagingService: messagingService,
                                   authService: authService)
messagingService.onTransientFailure = { [weak self] in self?.outboxService.flush() }
outboxService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
```
В края на `init` — **веднъж**: `outboxService.start()`.
После само `outboxService.flush()`: в `.sink` за активния акаунт (след `startListening()`),
в reconnect handler-а (Fixes3) и при `.active` от `scenePhase`.
В logout handler-а: `self?.outboxService.reset()`.

## 6. ChatViewModel.swift

**#10** — в `send()`, в общия `catch` (и в `sendMediaGuarded`):
```swift
} catch where OutboxService.isTransient(error) {
    // Stays as "waiting to send" and goes out by itself — no error banner.
    errorMessage = nil
    canRetryLastSend = false
    reload()
}
```
(сложи го **преди** последния общ `catch`).

**#1** — `DisplayMessage` получава `let isStarred: Bool` (от `message.isStarred` в `reload()`) и:
```swift
func toggleStar(_ message: DisplayMessage) {
    guard let me = authService.currentUserId else { return }
    try? messageRepository.setStarred(messageId: message.id, ownerUserId: me, isStarred: !message.isStarred)
    reload()
}
```
**#7** — `DisplayMessage` получава `let isSticker: Bool` (`mediaMetadata?.isSticker ?? false`) и:
```swift
func sendSticker(_ png: Data) async {
    await sendMediaGuarded { try await self.messagingService.sendSticker(png, in: self.conversation) }
}
```

## 7. MessageBubbleView.swift

Параметри: `var onToggleStar: () -> Void = {}`, `var onSaveSticker: ((Data) -> Void)? = nil`.

В менюто (до Info / Add to Shared Pad):
```swift
Button(action: onToggleStar) {
    Label(message.isStarred ? "Unstar" : "Star", systemImage: message.isStarred ? "star.slash" : "star")
}
```
Във footer-а, преди часа: `if message.isStarred { Image(systemName: "star.fill").font(.caption2) }`.

В `bubble`, **преди** `.image`:
```swift
} else if message.isSticker {
    StickerBubble(messageId: message.id, loader: mediaLoader, onSave: message.isMine ? nil : onSaveSticker)
```

## 8. ChatView.swift

```swift
@State private var showGallery = false
@State private var showStickers = false
@State private var showLockError: String?
@Environment(\.dismiss) private var dismissChat   // ако вече има dismiss — ползвай него
```
**Меню „⋯“:**
```swift
Button { showGallery = true } label: { Label("Media, files & starred", systemImage: "photo.on.rectangle") }
Button { toggleLock() } label: {
    Label(viewModel.conversation.isLocked ? "Unlock chat" : "Lock chat",
          systemImage: viewModel.conversation.isLocked ? "lock.open" : "lock")
}
```
**Меню „+“ (`AttachmentMenu`)** — `onSticker` → `showStickers = true` (`Label("Sticker", systemImage: "face.smiling.inverse")`).

**Sheets:**
```swift
.sheet(isPresented: $showGallery) {
    ChatMediaGalleryView(conversation: viewModel.conversation) { messageId in
        jumpTo(messageId)        // същото като при търсенето: ensureLoaded + proxy.scrollTo
    }
    .environmentObject(container)
}
.sheet(isPresented: $showStickers) {
    StickerPickerSheet { png in Task { await viewModel.sendSticker(png) } }
        .environmentObject(container)
}
.alert("Can't lock", isPresented: Binding(get: { showLockError != nil }, set: { if !$0 { showLockError = nil } })) {
    Button("OK", role: .cancel) {}
} message: { Text(showLockError ?? "") }
```
`jumpTo` изисква `proxy` — направи `@State private var jumpTarget: String?` и в `messageList`:
```swift
.onChange(of: jumpTarget) { _, id in
    guard let id, viewModel.ensureLoaded(id) else { return }
    withAnimation { proxy.scrollTo(id, anchor: .center) }
    jumpTarget = nil
}
```
и `jumpTo(_ id:) { jumpTarget = id }`.

**MessageBubbleView** в `ForEach`: `onToggleStar: { viewModel.toggleStar(message) }`,
`onSaveSticker: { data in Task { try? await container.stickerService.addReceived(data) } }`.

**#11 заключване:**
```swift
.chatLockGate(isLocked: viewModel.conversation.isLocked,
              lock: container.chatLockService,
              name: viewModel.peerUsername) { dismissChat() }
```
```swift
private func toggleLock() {
    guard let me = container.authService.currentUserId else { return }
    let locking = !viewModel.conversation.isLocked
    guard !locking || container.chatLockService.canAuthenticate else {
        showLockError = "Set a passcode (Settings → Face ID & Passcode) to lock chats."
        return
    }
    Task {
        // Both locking and unlocking need the owner — otherwise anyone holding
        // the unlocked phone could switch it off.
        let outcome = await container.chatLockService.authenticate(
            reason: locking ? "Lock this chat" : "Unlock this chat")
        guard outcome == .success else {
            showLockError = outcome.message
            return
        }
        try? container.conversationRepository.setLocked(
            conversationId: viewModel.conversation.id, ownerUserId: me, isLocked: locking)
        viewModel.reloadConversation()
    }
}
```
**Банер „чака изпращане“ (#10)** — в `bottomBar` над `noticeBars`:
```swift
if !container.outboxService.isOnline, container.outboxService.waitingCount > 0 {
    Label("No internet — \(container.outboxService.waitingCount) message(s) will send when you're back online",
          systemImage: "clock.arrow.circlepath")
        .font(.footnote).padding(10).notchStyle(chrome, cornerRadius: 14)
}
```

## 9. Списък с чатове — #11

**ConversationListViewModel.reload()** — преди `messagingService.previewText(...)`:
```swift
let preview = conversation.isLocked
    ? "🔒 Locked chat"
    : (last.map { messagingService.previewText(for: $0) } ?? "No messages yet")
```
(Кешът на прегледа от Pack4 — ключът да включва `isLocked`, иначе остава старият текст.)
Добави `isLocked` в `ConversationSummary`.

**ConversationListView** — всяко отваряне на чат минава през една функция
(редовете, напомнянето от QuickFeatures, новият чат от покана):
```swift
@State private var lockMessage: String?

private func open(_ conversation: Conversation) {
    guard conversation.isLocked else { navigateToConversation = conversation; return }
    Task {
        let outcome = await container.chatLockService.authenticate(reason: "Open your locked chat")
        if outcome == .success { navigateToConversation = conversation }
        else { lockMessage = outcome.message }
    }
}
```
Замени `navigateToConversation = summary.conversation` и в `openPendingReminder()` с `open(...)`.
В реда: `if summary.isLocked { Image(systemName: "lock.fill").font(.caption2) }`. Алерт за `lockMessage`.

Заключеният чат остава на мястото си в списъка (не се скрива и не се мести).

## 10. AccountDeletionService.swift

```swift
StickerService.deleteAll(ownerUserId: userId)
```
(Звездите и заключването са колони — изтриват се с редовете.)

---

## Решения, които взех

- **#10 само временните грешки се изпращат сами** (няма интернет, timeout, сървър 5xx/429, изтекла сесия). Постоянните (непознат, неприета покана, сменени ключове) остават с Retry — автоматичният опит никога не би минал. След 72 ч съобщението става „неуспешно“, за да не чака тихо.
- **Съобщенията към неприета покана не се пипат** — те се пращат при приемане, както досега.
- **#11 и заключването, и отключването искат Face ID/код** — иначе всеки с отключения телефон би го изключил. Без код на телефона заключване не е позволено (чатът не би могъл да се отвори пак). В симулатора без код — „Set a passcode“.
- **#7 изрязването е на телефона** (Vision, iOS 17), без интернет. В симулатора често не намира обект — пробвай на телефон или „Square“. Получен стикер се записва в колекцията **прекодиран**, никога в оригиналния вид.
- **#1 звездите и галерията са само на този телефон.** Галерията е в менюто „⋯“, заедно с отбелязаните, вместо отделни екрани.

## Ограничения
- Звездите и заключването **не влизат в бекъпа** (бекъпът ползва свой формат на съобщенията). Ако ги искаш там — добави `isStarred` в `BackupSnapshot.BackupMessage`.
- Опашката работи, докато приложението е отворено; при затворено нищо не се праща (iOS не дава фонова работа без платени услуги).
- Миниатюрите на видеа декриптират видеото за момент във временна защитена папка и го трият веднага.
