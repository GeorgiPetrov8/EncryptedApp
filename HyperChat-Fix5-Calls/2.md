# Покани (проблем 5) + обаждания — какво да направиш

## 1. Замени файловете

| Файл | Къде |
|---|---|
| `Models/DTOs.swift` | + `case call` |
| `Persistence/ConversationRepository.swift` | + `delete(id:ownerUserId:)` |
| `Services/InvitationService.swift` | |
| `Services/MessagingService.swift` | |
| `Services/CallService.swift` | |
| `Services/AppContainer.swift` | |
| `Views/ChatView.swift`, `ChatViewModel.swift` | |
| `Views/ConversationListView.swift`, `ConversationListViewModel.swift` | |
| `Views/InvitationsView.swift` | |
| `Views/CallView.swift` | |

`CallModels.swift` и `Conversation.swift` остават същите.

Ако в проекта е останал `ConversationRelationshipState.swift` от pack 8, изтрий го. Приложението използва `RelationshipState` от `Conversation.swift`, така че вторият тип е излишен.

**Махнат е `MessagingService.startConversation(withUsername:)`**. Той създаваше
директно приет чат и заобикаляше поканите. Ако компилаторът се оплаче, че го
вика друг файл, кажи ми кой файл е.

## 2. Една промяна в `AlarmService.swift`

`resolveConversation` там създава липсващ чат директно като приет, а това
заобикаля поканите. Замени метода с:

```swift
private func resolveConversation(with peerId: String, ownerUserId: String) throws -> Conversation {
    guard let existing = try conversationRepository.findDirectConversation(
        ownerUserId: ownerUserId, userA: ownerUserId, userB: peerId
    ) else {
        // No chat with this contact (yet): the alarm falls back to tasks.
        throw InvitationError.notAccepted
    }
    return existing
}
```

## 3. Info.plist — ЗАДЪЛЖИТЕЛНО

В Target → Info добави:

| Ключ | Стойност |
|---|---|
| `NSMicrophoneUsageDescription` | `HyperChat needs the microphone for calls and voice messages.` |
| `NSCameraUsageDescription` | (вероятно го имаш) |

**Без `NSMicrophoneUsageDescription` iOS спира приложението** при първия опит
да ползва микрофона. Това важи за обажданията и **също за гласовите
съобщения**. Ако досега не си записвал гласово съобщение, затова не си се
сблъсквал с този срив.

В **Signing & Capabilities → Background Modes** трябва да има отметка на
**Audio, AirPlay, and Picture in Picture**. Тя вече е нужна за алармата, а
поддържа и звука на обаждането, когато приложението е минимизирано.

## 4. Добави WebRTC

Xcode → **File → Add Package Dependencies…**

```
https://github.com/stasel/WebRTC.git
```

Избери най-новата версия и добави продукта **WebRTC** към таргета HyperChat.

Ако го пропуснеш, приложението пак ще се компилира, защото кодът е зад
`#if canImport(WebRTC)`. Тогава при опит за обаждане ще излезе съобщението
„Calling needs the WebRTC package“.

## 5. Сървър

В `src/validate.js` добави `'call'` към списъка с разрешени типове:

```js
const ALLOWED_CONTENT_TYPES = [
  'text', 'image', 'video', 'file',
  'notePad', 'receipt', 'profile', 'invite', 'call',
];
```

Без него сървърът отказва всяко обаждане с 400. Рестартирай сървъра след промяната.

## 6. Тест

Трябват два акаунта на **две устройства** или на два симулатора. За видео е
нужно поне едно истинско устройство, защото симулаторът няма камера.

**Покани:**
1. A → молив → потребителското име на B → Invite. Чатът на A се отваря с банер
   „Waiting for B to accept“. A пише нещо и съобщението стои с часовник.
2. B получава нотификация „New chat invitation“ и брояч върху иконата за покани.
3. B → Accept. A получава нотификация „Invitation accepted“, а натрупаните
   съобщения тръгват и часовникът става отметка.

**Обаждане:** в чата на A → иконата на телефон → Voice call. При B се отваря
екран за входящо обаждане.

## Как работи и какво не прави

**Покани:**
- Преди приемане се праща **само** самата покана. Чат, бележник, потвърждения,
  профилна снимка и обаждане се блокират на едно място в `MessagingService`.
- Ако двамата се поканят едновременно, това се приема като взаимно съгласие и
  чатът се отваря и за двамата.
- Ако приемането се загуби в мрежата, първото съобщение от B също се брои за
  приемане, така че двамата не остават да се чакат.
- Отказана покана се изтрива при отказалия. Изпращачът вижда „declined“ и може
  да покани отново.
- Нотификацията не съдържа бележката към поканата, защото иначе тя би се
  видяла на заключения екран.

**Нотификациите работят само докато приложението е отворено или скоро е
минимизирано.** За нотификации при напълно затворено приложение сървърът трябва
да изпраща APNs push. Това е отделна задача и изисква Apple Developer акаунт с
push сертификат.

**Обаждания — ограничения:**
- **Няма TURN сървър.** Около 10–20% от връзките няма да се свържат: при строг
  NAT, в корпоративни мрежи и при някои мобилни оператори. Сега след 30 секунди
  се показва ясна грешка, вместо да виси на „Connecting…“.
- **Без CallKit.** Входящо обаждане се вижда само при отворено приложение.
  Звънене на заключен екран изисква CallKit + PushKit (VoIP push).
- Видео не може да се **добави** към гласово обаждане. Бутонът за камера се
  показва само при видео обаждане.
- Споделянето на екран изисква Broadcast Upload Extension, отделен таргет.
  Бутонът казва това, вместо просто да не прави нищо.
