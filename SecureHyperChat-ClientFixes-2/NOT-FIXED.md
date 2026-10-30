# Какво НЕ е поправено в този пакет и защо

| ID | Причина |
|---|---|
| R1 (част) | One-time ключът се трие преди успешен decrypt (`CryptoService.consumeOneTimePreKey`). Нужен е „peek“ метод в `CryptoService` — файлът не е пренаписан. Останалото от R1 е поправено. |
| S7, S40 | AAD/replay — промяна в протокола (`DoubleRatchet`), несъвместима със стари версии; прави се заедно със S8. |
| S8 | Domain separation — клиент + сървър + миграция на prekeys. |
| R5, R6 | 401 и close кодове — отделният пакет SessionRenewal / плъзгаща сесия; `RealWebSocketService` не е пренаписан. |
| R8 | Токен по потребител — засяга Auth/RealAPIClient/WebSocket едновременно. |
| S20 | Порт за споделяне на екрана — двата таргета + App Group. |
| S26, S42 | `AttachmentPolicy`, `GIFLoader` — не са пренаписани. |
| S33 | Бележникът в plaintext — нужна е миграция на базата. |
| S35, S36, S38, S39 | Фонове при logout, ntfy тема в Keychain, проверки в receipts, скрийншоти. |
| S43 (част) | Текстовете във Login/Register/Backup екраните. |
| R24 (част) | Потоков бекъп — само по-ясно съобщение за лимита. |
| R25 | Пагинация на чата. |
| F*, D1–D7, D9–D13 | Конфигурация (повечето в пакета Hardening: project.yml, .gitignore). |
| S2, S10, S11, S14, S15, S16 | Сървърни. |
