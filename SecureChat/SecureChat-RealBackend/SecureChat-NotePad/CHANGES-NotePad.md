# SecureChat — Shared Note/Todo/Buy Pad

Един споделен, checkbox-ируем списък per разговор — бележка, todo или
покупателски списък, който и двете страни виждат и редактират, с тикчета
за завършено. Минава през **същия** E2E криптиран канал като чат
съобщенията (X3DH/Double Ratchet), но не се показва като чат балон.

## Нови файлове

| Файл | Роля |
|---|---|
| `Models/NotePadItem.swift` | Домейн модел + GRDB запис (composite key) |
| `Models/NotePadOperation.swift` | Wire DTO — пълното състояние на един item, минаващо през шифрования канал |
| `Persistence/NotePadRepository.swift` | CRUD + LWW merge правилото |
| `Services/NotePadService.swift` | Локални мутации, merge, публикуване към UI, transmit hand-off |
| `Views/NotePadViewModel.swift` | Live-обновяващ се списък, сортиране, delete/rename |
| `Views/NotePadView.swift` | Списък с checkbox-и, inline edit, swipe-to-delete, add field |

## Заменени файлове

| Файл | Промяна |
|---|---|
| `Models/DTOs.swift` | нов `EnvelopePayloadKind` enum; `EnvelopeDTO.contentType` вече от този тип, не `MessageContentType` |
| `Persistence/MessageRepository.swift` | нов `markEnvelopeProcessed` — replay защита без `Message` ред |
| `Persistence/DatabaseManager.swift` | **v7** миграция (`note_pad_items`), регистрирана директно в migrator-а |
| `Services/MessagingService.swift` | notepad routing в `handleIncoming`; `sendNotePadOperation`; извлечен `transmitEnvelope` helper |
| `Services/AccountDeletionService.swift` | + `notePadRepository.deleteAll` |
| `Services/AppContainer.swift` | wiring на notepad + обединено с real-backend и media пакетите |
| `Views/ChatView.swift` | toolbar бутон „checklist" с брояч на незавършени, sheet за `NotePadView` |

Сървърна промяна (приложена директно и **тествана в тази сесия**):
`SecureChatServer/src/validate.js` — `'notePad'` добавен към allow-list-а за
`contentType`. Сървърът никога не интерпретира ciphertext, така че това е
цялата промяна — виж новия тест по-долу.

---

## Как работи merge-ът (и как го проверих, преди да го пиша в Swift)

Всеки item носи пълното си състояние (`text`, `isDone`, `isDeleted`,
`updatedAt`, `updatedBy`) — не incremental delta-и. При конфликт печели
по-новият `updatedAt`; при точно съвпадение — по-големият `updatedBy`
(детерминистично, без двете страни да се съгласуват).

**Преди да пиша и ред Swift**, симулирах точно това правило в самостоятелен
JS скрипт и проверих четири свойства с property-базирани тестове:

1. **Комутативност** — резултатът не зависи от реда на доставка (важно,
   защото notepad операциите минават през същата offline опашка с
   out-of-order доставка като съобщенията, #8/#12).
2. **Идемпотентност** — повторно приложение на същата операция (replay,
   припокриване между backfill и live stream) е no-op.
3. **Детерминистичен tie-break** — при точен timestamp match, двете страни
   стигат до един и същ победител без комуникация.
4. **Tombstone семантика** — по-късно "възкресяване" печели над по-ранно
   изтриване, независимо от реда на пристигане.

Всичките осем проверки минаха (`node merge_check.js`) преди да напиша
`NotePadRepository.merge`, което е директен превод на същата логика.

## Защо `EnvelopePayloadKind`, не разширен `MessageContentType`

`MessageContentType` е и типът на `Message.contentType` — колона на
редове, които стават чат балони, се показват в preview-то на списъка и
т.н. Notepad операция **никога** не става `Message` ред. Добавяне на
`.notePad` към `MessageContentType` щеше да принуди всеки exhaustive
`switch` върху него (иконата на балона, preview текстът, media detection)
да добави case, който компилаторът не може да потвърди, че е недостижим —
чисто defensive dead code.

Вместо това `EnvelopePayloadKind` е отделен тип, само за
`EnvelopeDTO.contentType`, с `asMessageContentType` bridge, който връща
`nil` точно за `.notePad`. Прави невъзможното състояние непредставимо,
не просто недостижимо. Практическа полза: `MessageBubbleView`,
`ChatViewModel`, `ConversationListViewModel` — всички непроменени от
photo picker пакета — остават валидни без нито един допълнителен switch.

Server-side: `validate.js` проверява суровия JSON string
(`'text'|'image'|'video'|'file'|'notePad'`), независимо кой Swift enum
стои зад него — жичният формат е идентичен.

## Защо не hard delete

Swipe-to-delete записва `isDeleted: true` през същия merge, не трие реда.
Hard delete в момента на swipe-а би счупил конвергенцията: ако peer-ът е
бил офлайн с чакаща редакция на същия item (напр. току-що го е тикнал
точно преди да загуби връзка), тази редакция, пристигнала **след** hard
delete, няма срещу какво да се merge-не — и в зависимост от insert/update
семантиката, редът или тихо възкръсва без памет за изтриването, или
изчезва напълно. Tombstone-ът участва в същото last-write-wins сравнение
като всяко друго поле.

## Интеграция с останалите пакети

`AppContainer.swift` тук е **обединена** версия на трите предишни варианта
(pack6 base + RealBackend mock/real switch + notepad wiring) — не поредна
delta. Ако прилагаш пакетите последователно, използвай тази версия като
финална, не пакетите поотделно.

`ChatView.swift` тук вече включва photo picker интеграцията отгоре —
взето от последния фактически файл в `SecureChat-PhotoPicker/`, не от
по-стара версия, за да няма разминаване.

---

## Умишлени ограничения

- **Няма outbox/retry опашка за неуспешен transmit.** Локалната редакция
  винаги се merge-ва трайно (потребителят никога не губи собственото си
  тикване), но ако `sendHandler` хвърли грешка (напр. няма мрежа в момента),
  нищо не пренасочва автоматично — следваща успешна редакция на **същия**
  item носи пълно състояние напред и се самоизлекува, но ако устройството
  просто не изпрати нищо повече за него, peer-ът не го вижда, докато не се
  появи следваща промяна. Пълно решение изисква dedicated outbox таблица
  с retry — извън обхвата тук.
- **`contentType` изтича като метаданни в清 текст**, включително сега
  `'notePad'` — вече съществуващо свойство на протокола (сървърът винаги е
  виждал дали дадено съобщение е text/image/video/file), не нова регресия.
- **Само 1:1** — цялото приложение е двустранни разговори; pad-ът наследява
  същото ограничение, не group chat.

## Какво остава

Не е компилирано (същото ограничение като целия проект). Най-рисково при
първи билд: GRDB composite `t.foreignKey(...)` синтаксисът в миграция v7
(вече използван успешно в v5/v6, така че моделът е доказан в тази кодова
база); `NotePadItem`'s computed `id` да не се обърка с Codable синтеза
(потвърдено коректно — computed properties не участват в автоматичен
Codable).
