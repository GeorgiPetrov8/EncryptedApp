# Pack 14 — фон и запис

## Файлове
- `Views/AppScreenStyle.swift` — замени целия файл.
- `Views/NewInvitationView.swift` — замени (ако структурата ти се казва
  иначе, запази твоето име и копирай само `body`).
- `Views/RecordingWaveform.swift` — нов.

## 1. Section → ThemedSection
Във всеки екран с `.appScreenStyle()` (Settings, Notifications, Account
recovery, Appearance, Alarms, Verify security, Notepad) смени:

    Section {          →  ThemedSection {
    Section("Title") { →  ThemedSection("Title") {

`header:` / `footer:` остават същите. Махни ръчните
`.foregroundStyle(container.appearanceStore.barTint)` — вече не трябват.

## 2. ChatView — думата „Chats“ сменя цвета
В `ChatView.body`, при другите модификатори (до `.toolbar(.hidden, for: .navigationBar)`):

    .appNavigationBarStyle(appearanceStore.appTheme)

## 3. Запис — анимацията през първата секунда
В `VoiceMessageViews.swift`, във `VoiceRecordingBar`, замени

    LiveWaveform(level: recorder.level)

с

    RecordingWaveform(level: recorder.level, isPaused: recorder.isPaused)

и изтрий `private struct LiveWaveform`.

По желание (по-бърз старт на микрофона): в `ChatView` `.onAppear` добави

    DispatchQueue.global(qos: .userInitiated).async {
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
    }

(`import AVFoundation` горе). Само задава категорията — микрофонът не се включва.
