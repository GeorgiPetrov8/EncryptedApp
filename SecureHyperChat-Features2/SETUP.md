# Функции: 3 „пише…“, 9 батерия, 8 локация, 20 предизвикателства, 15 обща дата

Прилага се след Pack4 и QuickFeatures. Swift кодът не е компилиран (проверени са само
скобите). Сървърният `src/ephemeral.js` е пуснат с 19 проверки — всички минават
(първоначално хванаха бъг: първият сигнал се режеше от таймера, поправено).

## Нови файлове

| Файл | |
|---|---|
| `Models/EphemeralFrames.swift` | #3 #9 кадри |
| `Services/TypingService.swift` | #3 |
| `Services/BatteryShareService.swift` | #9 (изключено по подразбиране) |
| `Views/PeerStatusLine.swift` | #3 #9 ред под името + „X is typing…“ |
| `Models/LocationAttachment.swift` | #8 |
| `Services/LocationService.swift` | #8 едно определяне, без следене |
| `Views/LocationViews.swift` | #8 лист за изпращане + балон |
| `Models/Challenge.swift` | #20 |
| `Services/ChallengeService.swift` | #20 |
| `Views/ChallengeViews.swift` | #20 карта, избор, настройка 18+ |
| `Resources/challenges.json` | #20 — 60 предизвикателства, **добави в таргета** |
| `Models/Occasion.swift` | #15 |
| `Services/OccasionService.swift` | #15 |
| `Views/OccasionViews.swift` | #15 конфети + лист |
| `Server/src/ephemeral.js` | #3 #9 сървър |

---

## 1. Сървър

**`src/validate.js`** — добави два контролни типа (локацията и картата пътуват в текстовото съобщение и не искат промяна):
```js
'text', 'image', 'video', 'file', 'notePad', 'receipt', 'profile', 'invite', 'call', 'edit', 'reaction',
'challengeUpdate', 'occasion',
```
Ако сървърът изисква връзка/покана за контролни съобщения (ServerFixes, S15), двата нови типа минават по същото правило — не ги добавяй към изключенията за непознати.

**`server.js`**:
```js
const { Ephemeral } = require('./src/ephemeral');
// в main():
const ephemeral = new Ephemeral();
```
В WebSocket обработчика, **след** `presence.register(userId, conn)`:
```js
ephemeral.register(userId, conn);
conn.on('close', () => ephemeral.unregister(userId, conn));
```
В обработката на кадрите (до `contacts` / `presenceState`):
```js
if (data.type === 'contacts') {
  presence.setContacts(userId, data.userIds);
  ephemeral.setContacts(userId, data.userIds);
} else if (data.type === 'presenceState') {
  presence.setVisible(userId, data.visible !== false);
  ephemeral.setVisible(userId, data.visible !== false);
} else if (data.type === 'typing') {
  ephemeral.handleTyping(userId, data);
} else if (data.type === 'battery') {
  ephemeral.handleBattery(userId, data);
}
```
Лимитът `WS_FRAMES_PER_WINDOW = 40` за 10 s стига (клиентът праща „пише…“ най-много на 3 s).

## 2. Info.plist / project.yml

```yaml
NSLocationWhenInUseUsageDescription: "SecureHyperChat uses your location only when you choose to share it in a chat."
LSApplicationQueriesSchemes:
  - comgooglemaps
```

## 3. DatabaseManager.swift — миграция

След последната (напр. `v13_nicknames_subtasks`):
```swift
/// #20 challenge status, #15 shared date. Local per account; the other phone
/// keeps its own copy, kept in step by control messages.
migrator.registerMigration("v14_challenges_occasions") { db in
    try db.create(table: "challenge_states") { t in
        t.column("ownerUserId", .text).notNull()
        t.column("conversationId", .text).notNull()
        t.column("messageId", .text).notNull()
        t.column("status", .text).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.primaryKey(["ownerUserId", "messageId"])
        t.foreignKey(["ownerUserId", "messageId"], references: "messages",
                     columns: ["ownerUserId", "id"], onDelete: .cascade)
    }
    try db.create(table: "occasions") { t in
        t.column("ownerUserId", .text).notNull()
        t.column("conversationId", .text).notNull()
        t.column("occasion", .text).notNull()   // JSON
        t.primaryKey(["ownerUserId", "conversationId"])
        t.foreignKey(["ownerUserId", "conversationId"], references: "conversations",
                     columns: ["ownerUserId", "id"], onDelete: .cascade)
    }
}
```
и `"v14_challenges_occasions"` в `expectedMigrationIdentifiers`.

## 4. DTOs.swift — `EnvelopePayloadKind`

```swift
case challengeUpdate
case occasion
```
И двата са **контролни**: в `isControlMessage` → `true`, в `asMessageContentType` → `nil`.
Компилаторът ще покаже всеки `switch`, който трябва да ги включи.

## 5. MessagePayloads.swift — `TextPayload`

Нови незадължителни полета (старите съобщения се четат както преди):
```swift
var location: LocationAttachment?
var challenge: ChallengeCard?
```
Добави ги в `init` със стойност `nil` по подразбиране и в `CodingKeys`, ако има.
Ако `TextPayload.decode` има собствена логика, при четене валидирай:
```swift
payload.location = payload.location?.validated()
payload.challenge = payload.challenge?.validated()
```

## 6. MessagingService.swift

**Изпращане** (до `sendGIF`):
```swift
/// #8. Text fallback for older app versions.
func sendLocation(_ location: LocationAttachment, in conversation: Conversation) async throws {
    let payload = TextPayload(text: LocationAttachment.fallbackText, location: location)
    try await send(plaintext: try payload.encoded(), contentType: .text, in: conversation)
}

/// #20.
func sendChallenge(_ card: ChallengeCard, in conversation: Conversation) async throws {
    let payload = TextPayload(text: "\(ChallengeCard.fallbackText): \(card.title)", challenge: card)
    try await send(plaintext: try payload.encoded(), contentType: .text, in: conversation)
}
```
**`canEdit`** — редакцията не важи за локация и карта:
```swift
&& textContent(for: message)?.location == nil
&& textContent(for: message)?.challenge == nil
```
(същото в `applyRemoteEdit`).

**`handleControlMessage`** — нови случаи. Добави `challengeHandler` и `occasionHandler` в `setControlHandlers`, както `receipt`:
```swift
case .challengeUpdate:
    guard let payload = try? decoder.decode(ChallengeUpdatePayload.self, from: plaintext) else { return }
    challengeHandler?(payload, conversation, envelope.senderId)
case .occasion:
    guard let payload = try? decoder.decode(Occasion.self, from: plaintext) else { return }
    occasionHandler?(payload, conversation, envelope.senderId)
```

**`previewText`** за `.text`:
```swift
if let payload = textContent(for: message) {
    if payload.location != nil { return "📍 Location" }
    if let card = payload.challenge { return "\(card.category.emoji) Challenge" }
}
```

## 7. WebSocket

**`WebSocketServiceProtocol`**:
```swift
func sendEphemeral(_ frame: EphemeralOutgoing)
func ephemeralFrames() -> AsyncStream<EphemeralFrame>
```
`MockWebSocketService`: празни реализации (`AsyncStream { $0.finish() }`).

**`RealWebSocketService`** — същият модел като `presenceContinuation`:
```swift
private var ephemeralContinuation: AsyncStream<EphemeralFrame>.Continuation?

func ephemeralFrames() -> AsyncStream<EphemeralFrame> {
    AsyncStream { continuation in
        lock.lock(); ephemeralContinuation?.finish(); ephemeralContinuation = continuation; lock.unlock()
    }
}

func sendEphemeral(_ frame: EphemeralOutgoing) {
    lock.lock(); let task = currentTask; lock.unlock()
    guard let task else { return }   // offline: dropped on purpose (ephemeral)
    task.send(.string(String(decoding: frame.json, as: UTF8.self))) { _ in }
}
```
В `receiveLoop`, в `switch frame.type`:
```swift
case "typing", "battery":
    if let parsed = EphemeralFrame.parse(data) {
        lock.lock(); let c = ephemeralContinuation; lock.unlock()
        c?.yield(parsed)
    }
```
В `runOneConnection`, след успешния вход (до `onAuthenticated()`) — сигнал, че връзката е нова, за да се прати батерията отново. Най-лесно: `reconnectHandler` вече се вика при повторна връзка; за първата добави в `AppContainer` `batteryService.connected()` след `startListening()` (виж по-долу).

## 8. AppContainer.swift

```swift
let typingService: TypingService
let batteryService: BatteryShareService
let challengeService: ChallengeService
let occasionService: OccasionService

// init, след presenceService и database:
self.typingService = TypingService(webSocket: webSocketService, presence: presenceService)
self.batteryService = BatteryShareService(webSocket: webSocketService)
self.challengeService = ChallengeService(dbQueue: database.dbQueue,
                                         messageRepository: messageRepository,
                                         authService: authService)
self.occasionService = OccasionService(dbQueue: database.dbQueue, authService: authService)

// след messagingService:
challengeService.configure(
    cardLookup: { [weak messagingService] message in messagingService?.textContent(for: message)?.challenge },
    send: { [weak messagingService] payload, conversation in
        try await messagingService?.sendControlPayload(payload, kind: .challengeUpdate, in: conversation)
    }
)
occasionService.setSendHandler { [weak messagingService] occasion, conversation in
    try await messagingService?.sendControlPayload(occasion, kind: .occasion, in: conversation, createdAt: occasion.setAt)
}
// в setControlHandlers:
challenge: { [weak challengeService] payload, conversation, senderId in
    challengeService?.applyRemote(payload, from: senderId, conversation: conversation, ownerUserId: conversation.ownerUserId)
},
occasion: { [weak occasionService] occasion, conversation, senderId in
    occasionService?.applyRemote(occasion, from: senderId, conversation: conversation, ownerUserId: conversation.ownerUserId)
},

// получаване на кадрите:
Task { [weak self] in
    guard let self else { return }
    for await frame in self.webSocketService.ephemeralFrames() {
        switch frame {
        case .typing(let from, let isTyping): self.typingService.apply(from: from, isTyping: isTyping)
        case .battery(let from, let level, let charging, let at): self.batteryService.apply(from: from, level: level, charging: charging, at: at)
        }
    }
}
// ново съобщение спира „пише…“:
messagingService.$incomingMessage
    .compactMap { $0?.message.senderId }
    .sink { [weak self] in self?.typingService.messageArrived(from: $0) }
    .store(in: &cancellables)
```
В `.sink` за активния акаунт, след `messagingService.startListening()`:
```swift
self.batteryService.activate()
self.batteryService.connected()
```
и в reconnect handler-а (Fixes3) добави `self.batteryService.connected()`.
В logout handler-а: `self?.typingService.reset()`, `self?.batteryService.reset()`.
Препращане на промените (за да се обновяват изгледите):
```swift
typingService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
batteryService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
```

## 9. ChatView / ChatViewModel / MessageBubbleView

**Ред под името** — в `ChatHeaderNotch` замени текста „online“ с:
```swift
PeerStatusLine(
    isOnline: isOnline,
    isTyping: peerId.map { container.typingService.isTyping($0) } ?? false,
    battery: peerId.flatMap { container.batteryService.reading(for: $0) }
)
```
**„X is typing…“** над композера (в `bottomBar`, преди `noticeBars`):
```swift
if let peerId = viewModel.peerId, container.typingService.isTyping(peerId) {
    TypingIndicator(name: viewModel.peerUsername)
        .notchStyle(chrome, cornerRadius: 14)
        .transition(.opacity)
}
```
**Изпращане на „пише…“** — на `ChatView`:
```swift
.onChange(of: viewModel.draftText) { _, text in
    guard let peerId = viewModel.peerId else { return }
    container.typingService.draftChanged(text, peerId: peerId,
                                         canSend: viewModel.relationshipState == .accepted)
}
.onDisappear { if let peerId = viewModel.peerId { container.typingService.stopped(peerId: peerId) } }
```
и в `ChatViewModel.send()` след успешно изпращане — `typingService.stopped(peerId:)` (или от `ChatView` в `onSend`).

**Меню „+“ (`AttachmentMenu`)** — два нови бутона и параметри `onLocation`, `onChallenge`:
```swift
Button(action: onLocation) { Label("Location", systemImage: "location") }
Button(action: onChallenge) { Label("Challenge", systemImage: "dice") }
```
В `ChatView`:
```swift
@State private var showLocation = false
@State private var showChallenges = false
@State private var showOccasion = false
@State private var confetti = false

.sheet(isPresented: $showLocation) {
    ShareLocationSheet { location in
        Task { try? await container.messagingService.sendLocation(location, in: viewModel.conversation); viewModel.reload() }
    }.environmentObject(container)
}
.sheet(isPresented: $showChallenges) {
    ChallengePickerSheet { card in
        Task { try? await container.messagingService.sendChallenge(card, in: viewModel.conversation); viewModel.reload() }
    }.environmentObject(container)
}
.sheet(isPresented: $showOccasion) {
    OccasionSheet(conversation: viewModel.conversation, peerName: viewModel.peerUsername)
        .environmentObject(container)
}
```
(Локацията и предизвикателствата да са недостъпни, ако чатът не е приет — както бележника.)
В менюто „⋯“: `Button { showOccasion = true } label: { Label("Shared date", systemImage: "calendar.badge.plus") }`.

**Конфети и банер** (#15):
```swift
.overlay { if confetti { ConfettiView { confetti = false } } }
.onAppear {
    if container.occasionService.celebrationIfDue(for: viewModel.conversation.id) != nil { confetti = true }
}
```
Банер, в `topBar` под лентата:
```swift
if let banner = container.occasionService.bannerText(for: viewModel.conversation.id) {
    Text(banner).font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity).padding(10)
        .notchStyle(chrome, cornerRadius: 16)
}
```
Обнови при промяна: `.onReceive(container.occasionService.updates) { if $0 == viewModel.conversation.id { /* refresh */ } }`
и за картите: `.onReceive(container.challengeService.updates) { if $0 == viewModel.conversation.id { viewModel.reload() } }`.

**`DisplayMessage`** — две полета, попълнени в `ChatViewModel.reload()` от `textContent(for:)`:
```swift
let location: LocationAttachment?
let challenge: ChallengeCard?
```
и `challengeStatus: ChallengeStatus` от `challengeService.statuses(messageIds:)` за страницата.

**`MessageBubbleView.bubble`** — преди обикновения текст:
```swift
} else if let location = message.location {
    LocationBubble(location: location, textColor: textColor, bubbleColor: bubbleColor)
} else if let card = message.challenge {
    ChallengeCardView(card: card, status: message.challengeStatus, isMine: message.isMine,
                      textColor: textColor, bubbleColor: bubbleColor, onRespond: onChallengeRespond)
```
с параметър `var onChallengeRespond: (ChallengeStatus) -> Void = { _ in }`, а в `ChatView`:
```swift
onChallengeRespond: { status in
    Task { try? await container.challengeService.respond(messageId: message.id, status: status, in: viewModel.conversation) }
}
```

## 10. SettingsView.swift

В `privacySection`:
```swift
Toggle("Share my battery level", isOn: Binding(
    get: { container.batteryService.isSharing },
    set: { container.batteryService.isSharing = $0 }
))
```
footer: „Off by default. Your contacts see your battery % while you're online. The server relays it (not end-to-end encrypted) and keeps it only in memory.“
И нова секция: `ChallengeSettingsSection()`.

## 11. AccountDeletionService.swift

```swift
container-level: challengeService.deleteAll(ownerUserId: userId)
                 occasionService.deleteAll(ownerUserId: userId)
```
(Таблиците се трият и каскадно с разговорите, но настройката „показано днес“ е в UserDefaults.)

---

## Решения, които взех

- **„Пише…“ и батерията минават през сървъра**, не са криптирани от край до край — както онлайн точката. Сървърът ги пази **само в паметта**, праща ги **само между взаимни контакти** и **никога** от човек, скрил онлайн статуса си.
- **Батерията е изключена по подразбиране**, праща се при промяна от 5 пункта или включване/изключване на зарядното, и изчезва, щом излезеш офлайн или я изключиш.
- **Локацията е една точка**, без проследяване, криптирана в съобщението. **Картата не се зарежда сама** — рисуването ѝ казва на Apple приблизително къде е точката; зарежда се с „Show map“.
- **Предизвикателство може да приеме, откаже и маркира като изпълнено само получателят**; статусът върви само напред. Пикантните (12 от 60) са закачливи, без експлицитно съдържание, скрити по подразбиране и се включват с потвърждение 18+.
- **Общата дата** се задава от всеки от двамата, синхронизира се, по-новата промяна печели. Конфетите излизат веднъж на ден за чат; при „Reduce Motion“ — само банер. 29 февруари се празнува на 28-и в невисокосни години. **Фонът не се сменя** — не исках да пипам запазения ти фон; банерът и конфетите са промяната.

## Ограничения
- „Пише…“ и батерията не стигат, ако някой от двамата е офлайн — по замисъл.
- Старите версии на приложението показват локацията и картата като текст („📍 Location“, „🎲 Challenge: …“).
- Списъкът с предизвикателства е вграден в приложението; нови се добавят с нова версия.
