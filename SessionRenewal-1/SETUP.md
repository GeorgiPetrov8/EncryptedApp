# Подновяване на сесията — какво да направиш

Сървърът не се променя. Трябва ти сървър с `POST /auth/logout` (от пакета HyperChat-Hardening).
Без него подновяването пак работи, само старият токен не се прекратява веднага.

## 1. Нов файл
`SessionRenewalService.swift` → добави го в таргета `SecureHyperChat`.

## 2. AppContainer.swift (3 места)

```swift
// при другите свойства
let sessionRenewal: SessionRenewalService

// веднага след self.authService = AuthService(...)
self.sessionRenewal = SessionRenewalService(
    authService: authService,
    apiClient: apiClient,
    cryptoService: cryptoService,
    tokenStore: tokenStore
)

// в authService.$currentUserId .sink, в клона `if userId != nil {`
self.sessionRenewal.renew(force: false)
```
и в списъка `forwarded`:
```swift
sessionRenewal.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
```

## 3. При отваряне на приложението
Там, където при `scenePhase == .active` викаш `appLockService.appWillEnterForeground()`
(в `SecureHyperChatApp.swift` или `RootView.swift`), добави:
```swift
container.sessionRenewal.appBecameActive()
```

## 4. RealAPIClient.swift — в `validate(...)`
```swift
case "notAuthenticated":
    NotificationCenter.default.post(name: .sessionRejectedByServer, object: nil)
    throw APIError.notAuthenticated
```

## 5. RealWebSocketService.swift — в `expectAuthOk(...)`, точно преди `throw`
```swift
NotificationCenter.default.post(name: .sessionRejectedByServer, object: nil)
```

## 6. След успешен вход/регистрация (по желание)
В `AuthService.login` и `establishSession` няма достъп до услугата, затова в
`AppContainer` в същия `.sink` можеш вместо `renew(force: false)` да викаш
`self.sessionRenewal.markFresh()` при нов вход. Ако не го направиш, първото
отваряне след входа подновява веднъж — безвредно.

## 7. Съобщение на екрана за вход (по желание)
```swift
if let message = container.sessionRenewal.endedMessage {
    Text(message).font(.footnote)
}
```

## Важно — Cloudflare
Всяко подновяване е 2 заявки към лимита за вход (10 в минута на IP). Зад Cloudflare
моят `rateLimit.js` взима адреса на Cloudflare, т.е. всички потребители делят една кофа.
За няколко тестови потребители е без значение; преди реално ползване оправи `clientIp`
(виж ПРОБЛЕМИ.md, S14).

## Как да провериш
1. В `server/src/auth.js` смени временно `SESSION_TTL_MS` на 2 минути, рестартирай.
2. Влез, изчакай 3 минути, прати съобщение → първото пада, приложението подновява
   само, следващото минава. В лога на телефона: „Session renewed“.
3. Върни стойността.
