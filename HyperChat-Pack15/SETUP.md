# Pack 15 — единна тема (фон, форми, листове, текст)

## 1. Файлове

**Нов (добави в проекта):** `AppTheme.swift`

**Замени (21):** `AppScreenStyle`, `AvatarView`, `AttachmentMenu`, `MessageStatusView`,
`MediaMessageView`, `MediaViews`, `MessageBubbleView`, `ChatView`, `ConversationListView`,
`SettingsView`, `NotificationSettingsView`, `RecoverySettingsView`, `RestoreAccountView`,
`VerifyIdentityView`, `AlarmEditView`, `AlarmListView`, `AppearanceSettingsView`,
`InvitationsView`, `NotePadView`, `EmojiPickerView`, `GIFPickerView`.

**Без промяна:** `AlarmRingingView`, `CallView`, `ScreenShareButton` (нарочно тъмни),
`ChatBackgroundView`, `DecryptedMediaCache`, `NavigationSwipeBack`,
`PhotoAttachmentLoader`, `VoiceMessageViews`.

Ако в проекта има отделен `NewInvitationView.swift`, изтрий го — класът е вътре в `InvitationsView.swift`.

Другите ти екрани (`LoginView`, `RegisterView`, `AppLockView`) не бяха в този пакет и остават със системен вид.
Ако искаш и те да са тематични, прати ги.

## 2. Какво беше причината (измерено върху целия RGB куб)

| # | Причина | Колко често |
|---|---|---|
| 1 | Лентата/редът ставаше толкова светъл, че искаше **черен** текст, докато заглавията (по фона) оставаха **бели** | 18,3% от цветовете |
| 2 | Синият балон на твоите съобщения се слива с фона | 61% от цветовете |
| 3 | Червен/зелен/оранжев текст се чете на цветен ред само при | 10,6% от цветовете |
| 4 | Текстът в входящите балони се сравняваше с фона, не с балона | мидтон фонове |
| 5 | Твърдо зададени `.secondary`, `.blue`, `Color.brand`, system material | навсякъде |
| 6 | Екрани и sheet-ове без `.appScreenStyle()` или с модификатор след `safeAreaInset` | виж по-долу |

## 3. Правилата сега

- Една повърхност (`surface`) за ленти, редове и входящи балони. Тя се измества в посоката, която **не** сменя цвета на текста → текстът е един и същ навсякъде (0,0% разминавания), контраст ≥ 4,58:1.
- Твоят балон е синьо само когато се отличава; иначе е инверсен.
- Вторичният текст е с пълна плътност (всяка прозрачност пада под 4,5:1 някъде) и се различава по размер и тегло.
- Статусите (грешка, успех, предупреждение) на собствен фон са цвета на текста + иконка; червено/зелено остава само на системния вид.

## 4. По файлове

| Файл | Проблем → поправка |
|---|---|
| AppScreenStyle / AppTheme | нова единна тема; `ThemedEmptyState`, `StatusText`, `ThemedRowButton`, `themedProminent/Bordered` |
| ChatView | лентите, банерите и NoticeBar са от темата; бутоните Accept/Decline не са син-на-син; емоджи sheet получава `container` |
| MessageBubbleView | цветове от темата (балони, час, тиктакове, reply иконка) |
| MessageStatusView | „прочетено" = по-плътно + цвят (не само синьо) |
| MediaMessageView / MediaViews | placeholder, реакции и GIF placeholder от темата; **счупен символ „Â·"** в „GIF · tap to load" |
| AttachmentMenu | „+" беше `Color.brand` върху композера |
| AvatarView | пръстенът на онлайн точката е цветът на лентата |
| ConversationListView | двоен `contentMargins`; празно състояние; редове от темата |
| NotePadView | `.plain` стил; **добавянето беше извън темата** (след `.appScreenStyle()`); двоен `.appScreenStyle()` |
| AppearanceSettingsView | двоен `.appScreenStyle()`; прегледът използва същата тема като чата; отметка за избрания режим |
| AlarmEditView | избран ден = син на син ред |
| InvitationsView | Accept/Decline; бележка в ред; празно състояние |
| RestoreAccountView / BackupPasswordSheet | нямаха `.appScreenStyle()` |
| EmojiPickerView / GIFPickerView | бяха чисто системни sheet-ове |
| Settings, Notifications, Recovery, Verify, AlarmList | сиви/червени/зелени текстове и бутони → теми |

## 5. Не е проверено

- Нищо от това не е компилирано. Най-вероятните места за грешка при билд: `ChromeStyle(fill:foreground:colorScheme:)` (ползва се memberwise init) и `AppearanceStore.averageColor(fileName:)`.
- Не е тествано на устройство как `Button(role: .destructive)` и `.plain` стил изглеждат върху цветен ред.
- Върху снимка текстът директно върху нея е гарантиран от затъмняването, а ленти/редове — от осреднения цвят на снимката.
