# Pack 10 — какво да направиш

## Swift: замени или добави файловете

| Файл | |
|---|---|
| `Models/Message.swift` | + `editedAt` |
| `Models/MessagePayloads.swift` | **нов** — отговор, редакция |
| `Models/DTOs.swift` | + `case edit` |
| `Models/ChatAppearance.swift` | + `RGB`, `ChromeStyle`, `AppearanceScope` |
| `Persistence/DatabaseManager.swift` | + миграция `v10_message_edits` |
| `Persistence/MessageRepository.swift` | + fetch / updateContent / delete |
| `Crypto/CryptoService.swift` | + export / import на ключове |
| `Services/BackupArchive.swift` | **нов** — криптиран формат на бекъпа |
| `Services/RecoveryAPI.swift` | **нов** |
| `Services/RecoveryService.swift` | **нов** |
| `Services/AuthService.swift` | + `adoptRecoveredSession` |
| `Services/MessagingService.swift` | отговори, редакция, възстановяване на сесия |
| `Services/AppearanceStore.swift` | + фон на списъка, среден цвят на снимка |
| `Services/VoiceRecorder.swift` | заключване, пауза |
| `Services/AppContainer.swift` | + `recoveryService` |
| `Views/ChatBackgroundView.swift` | + `notchStyle` |
| `Views/AppearanceSettingsView.swift` | три обхвата |
| `Views/ChatView.swift` | горна и долна плаваща лента, отговор, редакция |
| `Views/ChatViewModel.swift` | |
| `Views/MessageBubbleView.swift` | плъзгане, меню, цитат |
| `Views/VoiceMessageViews.swift` | |
| `Views/ConversationListView.swift` | фон и цветове |
| `Views/SettingsView.swift` | |
| `Views/RecoverySettingsView.swift` | **нов** |
| `Views/RestoreAccountView.swift` | **нов** |
| `Views/NavigationSwipeBack.swift` | **нов** |

## Swift: ръчна стъпка — бутон „Restore account“

На екрана за вход (вероятно `LoginView.swift`) добави:

```swift
@EnvironmentObject private var container: AppContainer
@State private var showRestore = false

// в body, под бутона за вход:
Button("Restore account") { showRestore = true }
    .sheet(isPresented: $showRestore) {
        RestoreAccountView().environmentObject(container)
    }
```

## Сървър

1. Замени `src/db.js`. Новите таблици се създават сами при старт.
2. Добави `src/mailer.js` и `src/routes/recoveryRoutes.js`.
3. В `src/validate.js` добави `'edit'` към разрешените contentType:
   ```js
   'text', 'image', 'video', 'file', 'notePad', 'receipt', 'profile', 'invite', 'call', 'edit',
   ```
4. В `server.js`, при другите `router.*`:
   ```js
   const recovery = require('./src/routes/recoveryRoutes');
   router.get('/account/email', recovery.getEmailRoute(store));
   router.post('/account/email', recovery.setEmailRoute(store, limiters));
   router.post('/account/email/verify', recovery.verifyEmailRoute(store, limiters));
   router.post('/account/email/remove', recovery.removeEmailRoute(store));
   router.post('/backup', recovery.uploadBackupRoute(store, limiters));
   router.post('/backup/delete', recovery.deleteBackupRoute(store));
   router.post('/recovery/start', recovery.startRecoveryRoute(store, limiters));
   router.post('/recovery/verify', recovery.verifyRecoveryRoute(store, limiters));
   router.get('/recovery/backup', recovery.downloadBackupRoute(store, limiters));
   router.post('/recovery/rebind', recovery.rebindRoute(store, limiters));
   ```
   Ако routerът ти не изпраща `X-Recovery-Ticket` хедъра до handler-а (той
   го чете от `req.headers`), кажи ми.
5. **Имейли.** Без настройка кодовете се отпечатват в конзолата на сървъра,
   което стига за тест. За реални имейли задай:
   ```
   RESEND_API_KEY=re_xxx
   MAIL_FROM="HyperChat <noreply@твоят-домейн>"
   ```
6. Тест: `node test/recovery.test.js` → `15 recovery tests passed`.

## Как да тестваш възстановяването

1. На телефон А: Settings → Account Recovery → добави имейл → въведи кода
   (взимаш го от конзолата на сървъра).
2. Export backup file → парола → Save to Files. Направи и „Back up to server“.
3. Изтрий приложението на А (или вземи друг симулатор).
4. Login екран → Restore account → Backup file → избери файла → паролата.
   Всичко се връща, а контактите могат да ти пишат веднага.
5. Повтори с Email → username → кода → паролата.
