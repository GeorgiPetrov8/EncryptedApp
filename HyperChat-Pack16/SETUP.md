# Pack 16

## Файлове
**Замени (13 изгледа):** `AppTheme`, `AppScreenStyle`, `ChatView`, `NotePadView`, `AlarmEditView`,
`AlarmListView`, `InvitationsView`, `RecoverySettingsView`, `RestoreAccountView`,
`VerifyIdentityView`, `AppearanceSettingsView`, `EmojiPickerView`, `GIFPickerView`.
**Замени:** `Services/VoiceRecorder.swift` (нов запис, виж долу).

## Микрофон — един ръчен ред във VoiceMessageViews.swift
Новият рекордер има `isCapturing` (= звукът наистина идва). Във `VoiceRecordingBar` покажи това,
за да съвпада екранът със записа:

    Circle().fill(.red).frame(width: 9, height: 9)
        .opacity(recorder.isCapturing ? (recorder.isPaused ? 0.3 : 1) : 0.25)

    if !recorder.isCapturing { Text("Starting…").font(.caption2) }
    else { Text(timeString(recorder.duration)) /* както досега */ }

    RecordingWaveform(level: recorder.level,
                      isPaused: recorder.isPaused || !recorder.isCapturing)

Публичният интерфейс (`start() throws`, `stop()`, `cancel()`, `lock()`, `pause()`, `resume()`,
`level`, `duration`, `isRecording`, `isLocked`, `isPaused`, `permissionStatus`,
`requestPermission()`) е същият като в Pack 10. Ако твоята версия на `VoiceRecordButton`/
`VoiceMessageViews` вика нещо друго (например `start()` като `async`), прати ги и ги сверявам.
Тествай на ИСТИНСКИ телефон — в симулатора микрофонът не отразява реалното забавяне.
