# Бързи функции: 4, 5, 2, 13, 14, 6

Прилага се след Pack4. Сървърът **не се променя** (нито нов тип съобщение, нито нов route).
Нищо не е компилирано — проверени са само скобите. Логиката на серията (#5) е проверена
с 3000 случайни проби, включително часови зони +5:30 и +5:45.

## Нови файлове (добави в таргета)

| Файл | Функция |
|---|---|
| `Models/NotePadSubtask.swift` | #13 подзадачи, лимити, правило за автоматично „готово“ |
| `Services/StreakService.swift` | #5 серия от дни |
| `Services/MessageReminderService.swift` | #14 напомняне + `ReminderRouter` |
| `Services/ChatSearchModel.swift` | #6 търсене + подчертаване |
| `Views/MessageInfoSheet.swift` | #4 |
| `Views/NicknameEditorSheet.swift` | #2 |
| `Views/StreakBadge.swift` | #5 |
| `Views/NotePadSubtasksView.swift` | #13 |
| `Views/ChatSearchBar.swift` | #6 |
| `Views/ReminderSheet.swift` | #14 |

Ползват `SafeText` (ClientFixes), `ThemedSection`, `StatusText`, `ThemedRowButton`,
`.themedBordered`, `.appScreenStyle()` (Pack15) и `notchStyle` (Pack10).

---

## 1. DatabaseManager.swift — миграция (задължително)

В `migrator`, **след последната ти миграция**:
```swift
/// #2 nicknames, #13 notepad subtasks. Both nullable: old rows and old
/// backups decode unchanged.
migrator.registerMigration("v13_nicknames_subtasks") { db in
    try db.alter(table: "users") { t in
        t.add(column: "nickname", .text)
    }
    try db.alter(table: "note_pad_items") { t in
        t.add(column: "subtasks", .text)   // JSON array
    }
}
```
и добави `"v13_nicknames_subtasks"` в `expectedMigrationIdentifiers`.
Ако вече имаш миграция с име `v13_…`, смени номера.

## 2. #2 Прякори

**User.swift** — ново поле и показване:
```swift
/// #2: private name chosen on this phone. Display only, never sent.
var nickname: String?
```
Ако `User` има ръчен `init`, добави параметър `nickname: String? = nil` и `self.nickname = nickname`.
Смени `shownName`:
```swift
var shownName: String {
    if let nickname, !nickname.isEmpty { return nickname }
    return username.isEmpty ? String(id.prefix(8)) : username
}
```
Провери, че всички места, които **показват** име, ползват `shownName`
(`ChatViewModel.peerUsername`, `ConversationListViewModel`, `InvitationsView`, `CallView`).
Там, където се **търси** човек (`fetch(ownerUserId:username:)`, покани), остава `username`.

**UserRepository.swift**:
```swift
func setNickname(ownerUserId: String, userId: String, nickname: String?) throws {
    try dbQueue.write { db in
        guard var user = try User.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: userId)) else { return }
        user.nickname = nickname
        try user.update(db)
    }
}
```
**Важно:** `pinOrCompareIdentity`, `upsertContactPlaceholder` и `updateUsername` не трябва да пипат `nickname`.

## 3. #13 Подзадачи в бележника

**NotePadItem.swift**:
```swift
/// #13. nil = no checklist. Optional so old backups decode.
var subtasks: [NotePadSubtask]?
```
(GRDB пази масива като JSON в колоната `subtasks`.) Ако има ръчен `init`, добави `subtasks: [NotePadSubtask]? = nil`.

**NotePadOperation.swift**:
```swift
/// #13. Optional: older phones ignore it, and send nil.
var subtasks: [NotePadSubtask]?
```
Където операцията се строи от item: `subtasks: item.subtasks`.
Където item се строи от **получена** операция:
```swift
// An older phone sends nil — keep our checklist instead of wiping it.
item.subtasks = NotePadSubtask.sanitized(operation.subtasks) ?? existing?.subtasks
```
(`existing` = локалният item със същия id, ако го има.)

**NotePadService.swift** — нов метод, **до `updateText`**, по същия начин като него:
```swift
/// #13. The whole item is the sync unit; uses the same clamped timestamp
/// and send path as `updateText`.
func updateSubtasks(_ item: NotePadItem, result: NotePadSubtaskEdit.Result, in conversation: Conversation) async {
    var updated = item
    updated.subtasks = result.subtasks.isEmpty ? nil : result.subtasks
    if let markDone = result.markDone { updated.isDone = markDone }
    // ↓ същото извикване, с което завършва updateText (apply / commit — както е при теб)
    await apply(updated, in: conversation)
}
```

**NotePadViewModel.swift**:
```swift
func updateSubtasks(_ item: NotePadItem, _ result: NotePadSubtaskEdit.Result) {
    Task { await notePadService.updateSubtasks(item, result: result, in: conversation) }
}
```

**NotePadView.swift** — в `NotePadRow` добави параметър `onSubtasks: (NotePadSubtaskEdit.Result) -> Void`,
`@State private var expanded = false`, и обвий текущия `HStack` така:
```swift
VStack(alignment: .leading, spacing: 4) {
    HStack(spacing: 12) {
        /* … текущото съдържание на реда … */
        Button {
            withAnimation { expanded.toggle() }
        } label: {
            HStack(spacing: 2) {
                if let progress = item.progress {
                    Text("\(Int(progress * 100))%").font(.caption2.monospacedDigit())
                }
                Image(systemName: expanded ? "chevron.up" : "checklist")
            }
            .font(.footnote)
            .foregroundStyle(theme.secondaryText)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide steps" : "Show steps")
    }
    if expanded {
        NotePadSubtasksView(item: item, onChange: onSubtasks)
    }
}
```
и подай `onSubtasks: { viewModel.updateSubtasks(item, $0) }` в двата `ForEach`.

## 4. ChatView.swift — #4, #14, #2, #5, #6

**Свойства:**
```swift
@StateObject private var search: ChatSearchModel
@State private var showSearch = false
@State private var infoMessage: DisplayMessage?
@State private var reminderMessage: DisplayMessage?
@State private var showNickname = false
@State private var notePadToast: String?
```
**В `init`:**
```swift
_search = StateObject(wrappedValue: ChatSearchModel(
    messageRepository: container.messageRepository,
    messagingService: container.messagingService
))
```

**`topBar`** — под `ChatHeaderNotch(...)`:
```swift
if showSearch {
    ChatSearchBar(model: search, chrome: chrome) { closeSearch() }
}
```

**`ChatHeaderNotch`** — нови параметри `streak: Int`, `onSearch: () -> Void`, `onNickname: () -> Void`.
До името: `StreakBadge(days: streak, compact: true)`. В менюто „⋯“:
```swift
Button(action: onSearch) { Label("Search", systemImage: "magnifyingglass") }
Button(action: onNickname) { Label("Nickname", systemImage: "pencil") }
```
При извикването:
```swift
streak: container.streakService.streak(for: viewModel.conversation),
onSearch: openSearch,
onNickname: { showNickname = true },
```

**`MessageBubbleView(...)`** в `messageList` — подай новите действия:
```swift
onInfo: { infoMessage = message },
onAddToNotePad: { addToNotePad(message) },
onRemind: { reminderMessage = message },
```

**В `messageList`**, на `ScrollView` (има достъп до `proxy`):
```swift
.onChange(of: search.currentMatchId) { _, id in
    guard let id else { return }
    if viewModel.ensureLoaded(id) {
        withAnimation { proxy.scrollTo(id, anchor: .center) }
    }
}
.onChange(of: viewModel.messages.last?.id) { _, _ in
    container.streakService.invalidate(conversationId: viewModel.conversation.id)
}
```
**Подчертаване** — на `messageList` (или целия body):
```swift
.environment(\.chatSearchTerm, showSearch ? search.highlightTerm : nil)
```

**Sheets** (до другите):
```swift
.sheet(item: $infoMessage) { message in
    MessageInfoSheet(message: message).environmentObject(container)
}
.sheet(item: $reminderMessage) { message in
    ReminderSheet(
        conversationId: viewModel.conversation.id,
        messageId: message.id,
        messagePreview: message.text,
        peerName: viewModel.peerUsername
    )
    .environmentObject(container)
}
.sheet(isPresented: $showNickname, onDismiss: { viewModel.reloadPeer() }) {
    if let peerId = viewModel.peerId,
       let peer = try? container.messagingService.contact(peerId) {
        NicknameEditorSheet(peerId: peerId, username: peer.username, current: peer.nickname)
            .environmentObject(container)
    }
}
.onDisappear { search.stop() }
```

**Помощни методи:**
```swift
private func openSearch() {
    guard let me = container.authService.currentUserId else { return }
    showSearch = true
    search.start(conversationId: viewModel.conversation.id, ownerUserId: me)
}

private func closeSearch() {
    showSearch = false
    search.stop()
}

private func addToNotePad(_ message: DisplayMessage) {
    let text = String(message.text.prefix(200))
    Task {
        await container.notePadService.addItem(text: text, in: viewModel.conversation)
        notePadToast = "Added to Shared Pad"
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        notePadToast = nil
    }
}
```
Тоста покажи където ти е удобно, напр. над `bottomBar`:
```swift
if let notePadToast { Text(notePadToast).font(.footnote).padding(8).notchStyle(chrome, cornerRadius: 12) }
```

## 5. ChatViewModel.swift — за #6

```swift
/// #6: loads older pages until the message is on screen.
@discardableResult
func ensureLoaded(_ messageId: String) -> Bool {
    var pages = 0
    while !messages.contains(where: { $0.id == messageId }) && hasOlder && pages < 200 {
        loadOlder()
        pages += 1
    }
    return messages.contains { $0.id == messageId }
}
```
(Ако `loadOlder()` при теб е `async`, направи метода `async` и добави `await` в ChatView.)

## 6. MessageBubbleView.swift — меню и подчертаване

**Нови параметри** (с подразбиране, за да не счупят другите извиквания):
```swift
var onInfo: () -> Void = {}
var onAddToNotePad: () -> Void = {}
var onRemind: () -> Void = {}
@Environment(\.chatSearchTerm) private var searchTerm
```
**В `contextMenu`**, след Reply/Copy, само ако съобщението не е `.undecryptable`:
```swift
if message.isMine {
    Button(action: onInfo) { Label("Info", systemImage: "info.circle") }
}
Button(action: onAddToNotePad) { Label("Add to Shared Pad", systemImage: "checklist") }
Button(action: onRemind) { Label("Remind Me", systemImage: "bell") }
```
„Add to Shared Pad“ скрий, ако разговорът не е приет (бележникът е заключен до приемане) — подай флаг `canAddToNotePad: viewModel.relationshipState == .accepted`.

**Подчертаване:** в текстовия балон смени
```swift
Text(message.text)
```
с
```swift
Text(SearchHighlight.attributed(message.text, term: searchTerm))
```

## 7. ConversationListView.swift — #5 и отваряне от напомняне

При `ConversationRow(...)` подай `streak: container.streakService.streak(for: summary.conversation)`.
В `ConversationRow` добави `let streak: Int` и до часа: `StreakBadge(days: streak, compact: true)`.

Отваряне на чат от напомняне:
```swift
.onReceive(NotificationCenter.default.publisher(for: .openConversationRequest)) { _ in
    openPendingReminder()
}
// и в .onAppear: openPendingReminder()

private func openPendingReminder() {
    guard let request = ReminderRouter.shared.takePending(),
          request.ownerUserId == container.authService.currentUserId,
          let conversation = try? container.conversationRepository.fetch(
              id: request.conversationId, ownerUserId: request.ownerUserId
          )
    else { return }
    navigateToConversation = conversation
}
```

## 8. AppDelegate.swift — докоснато напомняне

В `userNotificationCenter(_:didReceive:withCompletionHandler:)`, **преди** проверката за аларма:
```swift
if ReminderRouter.shared.handle(userInfo: response.notification.request.content.userInfo) {
    completionHandler()
    return
}
```
В `willPresent` за напомняния върни `[.banner, .sound, .list]`.

## 9. AppContainer.swift

```swift
let streakService: StreakService
let reminderService = MessageReminderService()
// в init, след database:
self.streakService = StreakService(dbQueue: database.dbQueue)
// след messagingService:
messagingService.$incomingMessage
    .compactMap { $0?.conversationId }
    .sink { [weak self] in self?.streakService.invalidate(conversationId: $0) }
    .store(in: &cancellables)
```
В logout handler-а: `self?.streakService.invalidateAll()` и `ReminderRouter.shared.clear()`.

## 10. AccountDeletionService.swift

Към локалното изтриване:
```swift
MessageReminderService.removeAll(ownerUserId: userId)
```

---

## Решения, които взех (кажи, ако искаш друго)

- **#14 напомнянето е обикновено известие, не аларма.** Алармите тук звънят до решаване на задачи — прекалено за „напомни ми да отговоря“. По подразбиране известието **не** съдържа текста на съобщението (видим на заключен екран); включва се с превключвател.
- **#5 серията** брои съобщения от двете страни (както пише в документа), показва се от 2 дни нагоре, само за приети чатове.
- **#13 правило за „готово“:** последната отметната стъпка маркира задачата като готова; размаркиране или нова стъпка я отваря отново; ръчната отметка на задачата остава независима.
- **#6 търсенето** обхожда целия чат (не само заредените 100), но само докато търсенето е отворено; индексът се изтрива при затваряне.
- **#2 прякорите** влизат в бекъп файла (полето е част от `User`).

## Ограничения
- Търсенето не намира текст в GIF, снимки и гласови съобщения, нито в бележника.
- Напомнянията не са синхронизирани между акаунти; изтриват се само при изтриване на акаунта.
- Стар телефон, който редактира задача, няма да изпрати подзадачите — запазват се локалните.
