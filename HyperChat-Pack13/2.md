# Pack 13 — какво да направиш

## 1. Замени / добави файлове

| Файл | |
|---|---|
| `Views/AppScreenStyle.swift` | замени (+ `Color.brand`) |
| `Views/ChatBackgroundView.swift` | замени |
| `Views/ChatView.swift` | замени |
| `Views/MessageBubbleView.swift` | замени |
| `Views/VoiceMessageViews.swift` | замени |
| `Views/InvitationsView.swift` | замени |
| `Views/AppearanceSettingsView.swift` | замени |
| `Views/ScreenShareButton.swift` | замени |
| `Views/EmojiPickerView.swift` | **нов** |
| `Services/VoiceRecorder.swift` | замени (+ `AudioSessionQueue`) |
| `Services/CallService.swift` | замени |

## 2. По един ред в твоите файлове

**NotePadView.swift, VerifyIdentityView.swift, AlarmListView.swift** — на основния
`List`/`Form` (вътре в `NavigationStack`, ако има такъв), след `.navigationTitle(...)`:
```swift
.appScreenStyle()
```
(`NotificationSettingsView` и `RecoverySettingsView` вече го имат от Pack 12 —
отстъпът отгоре идва автоматично.)

**Навсякъде в твоите файлове:** замени `Color.accentColor` / `.accentColor` с
`Color.brand`. Бързо: Xcode → Find → Replace `Color.accentColor` → `Color.brand`.
(`.tint(.accentColor)` → `.tint(Color.brand)`.)

**AppContainer.swift** — в `authService.setLogoutHandler { ... }` добави:
```swift
self.messagingService.clearReceiveError()
self.callService.clearError()
```

## 3. Тест

- Тъмен фон → собствените балончета са сини с бял текст, бутонът ▶ на гласово
  съобщение се вижда.
- Задържане върху съобщение при стандартния фон → без квадрат зад балончето.
- Задържане → „Add reaction…“ → търсене („heart“, „fire“) или „Type any emoji“
  за знамена и тен на кожата.
- Споделяне на екрана — **само на истински iPhone** (в симулатора не работи и
  вече го казва). И двата телефона трябва да са с тази версия.
