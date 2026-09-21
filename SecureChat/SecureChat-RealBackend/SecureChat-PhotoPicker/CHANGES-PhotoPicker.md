# SecureChat — Photo Picker (свързва UI-то с готовия media backend)

Затваря веригата, отбелязана като липсваща във всеки предишен changes-файл:
`MessagingService.sendMedia` / `MediaEncryptionService` / реалният сървърен
`/media` route вече работеха end-to-end, но `ChatView` нямаше бутон, който
да ги задейства.

## Нови файлове

| Файл | Роля |
|---|---|
| `Views/PhotoAttachmentLoader.swift` | `PhotosPickerItem` → компресирани JPEG байтове (пълен размер + thumbnail) |
| `Views/DecryptedMediaCache.swift` | In-memory кеш на декриптирани снимки, за да не се декриптира на всеки scroll |
| `Views/MediaMessageView.swift` | Показва снимката inline + fullscreen viewer с pinch-to-zoom |

## Заменени файлове

| Файл | Промяна |
|---|---|
| `Views/MessageBubbleView.swift` | нов `mediaLoader` параметър (default no-op); `.image` вече рендира `MediaMessageView`, не икона + текст „📷 Photo" |
| `Views/ChatViewModel.swift` | `selectedPhotoItem`, `isSendingMedia`, `sendPhoto`, `loadMediaData`, `messagesById` |
| `Views/ChatView.swift` | `PhotosPicker` бутон (paperclip) в `MessageInputBar`, indicator при изпращане |

---

## Избори и защо

**`PhotosPicker`, не `PHPickerViewController`.** SwiftUI-нативният picker
(PhotosUI, iOS 17+ таргетът вече го покрива) не иска permission prompt за
достъп до библиотеката при единичен избор — системният picker работи
извън процеса на приложението и връща само избраните байтове. По-малко код,
по-добро съответствие с privacy позата на приложението.

**Picked = Sent, без потвърждение.** Избор на снимка директно тръгва
`sendPhoto` — същият модел като бутона за текст (едно действие, не
compose-then-confirm). `didSet` на `selectedPhotoItem` guard-ва срещу `nil`,
за да не влезе в цикъл при собственото си нулиране в `defer`.

**ImageIO downsampling, не `UIImage` + `UIGraphicsImageRenderer`.**
`CGImageSourceCreateThumbnailAtIndex` декодира директно на целевия размер —
пиковата памет следва **изходния**, не изходния размер на снимката.
Разликата е 10x на съвременна 48MP камера. `kCGImageSourceCreateThumbnailWithTransform`
бakva EXIF ориентацията, за да не излиза снимката настрани.

**Винаги JPEG на изхода**, независимо от източника (HEIC, PNG) —
предвидим формат за `MediaItem.mediaType`, без нужда да се помни и
възстановява оригиналния кодек.

**`mediaLoader` като closure, не директна референция към `MessagingService`.**
`MediaMessageView` и `MessageBubbleView` остават лесни за preview/тест в
изолация; `ChatViewModel` е единственото място, което знае как всъщност
се декриптира.

**`NSCache`, не ръчен size cap.** Евиктва сам под memory pressure; най-лошият
случай при евикция е един допълнителен decrypt, не грешка — байтовете са
или на диск (`MediaCacheStore`), или пак теглими от сървъра.

## Ограничения (умишлено извън обхват)

- **Само снимки** (`matching: .images`). Видео изисква различна thumbnail
  логика (`AVAssetImageGenerator`) и chunked upload — вече отбелязано като
  бъдеща работа в `SecureChatServer/README.md`.
- **Без preview/crop екран** преди изпращане — picked = sent директно.
- **Без zoom извън fullscreen viewer-а** — inline балонът е статичен размер.

## Какво остава

Не е компилирано (същото ограничение като целия проект — няма Xcode тук).
Рискови места при първи билд:
- `PhotosPickerItem` в `@Published` property — изисква `import PhotosUI` в
  `ChatViewModel.swift` (добавено); проверка за Sendable conformance при
  strict concurrency режим, ако проектът някога го включи.
- `.task(id: messageId)` в `MediaMessageView` — стандартен API, но провери
  версията на SwiftUI/iOS deployment target (17.0, вече покрито от
  `project.yml`).
