# ntfy известия — какво да направиш

## Swift

1. Добави `Services/NtfyService.swift` и `Views/NotificationSettingsView.swift`.

2. **AppContainer.swift** — три места:

   При другите `let` свойства:
   ```swift
   let ntfyService: NtfyService
   ```

   Веднага след `self.pushService = PushService(...)`:
   ```swift
   self.ntfyService = NtfyService(tokenStore: tokenStore, authService: authService)
   ```

   В `authService.setLogoutHandler { ... }`, до `pushService.unregister(...)`:
   ```swift
   self.ntfyService.signedOut(bearer: tokenStore.currentToken)
   ```

   В `authService.$currentUserId` sink-а, вътре в `Task { ... }` при влизане:
   ```swift
   await self.ntfyService.signedIn()
   ```

   И в списъка `forwarded`:
   ```swift
   ntfyService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
   ```

3. **SettingsView.swift** — в `accountSection` (или където искаш):
   ```swift
   NavigationLink {
       NotificationSettingsView()
   } label: {
       Label("Notifications", systemImage: "bell")
   }
   ```

4. **URL scheme** (за да отваря HyperChat при натискане на известието):
   Target → **Info → URL Types → +** → Identifier `com.hyperchat.app`,
   URL Schemes `hyperchat`. Без това натискането отваря ntfy.

## Сървър

1. Добави `src/ntfy.js` и `src/routes/ntfyRoutes.js`. `db.js` не се променя —
   таблицата се създава автоматично.

2. В `server.js`:
   ```js
   const { Ntfy } = require('./src/ntfy');
   const ntfyRoutes = require('./src/routes/ntfyRoutes');
   const ntfy = new Ntfy(store);

   router.get('/devices/ntfy', ntfyRoutes.getNtfyRoute(store, ntfy));
   router.post('/devices/ntfy', ntfyRoutes.setNtfyRoute(store, limiters, ntfy));
   router.post('/devices/ntfy/test', ntfyRoutes.testNtfyRoute(store, limiters, ntfy));
   ```

3. В `src/routes/messageRoutes.js`, след като envelope-ът е записан в опашката
   (на същото място като `pushForEnvelope`, ако си го добавил):
   ```js
   ntfy.notifyForEnvelope(body, presence).catch(() => {});
   ```
   `ntfy` трябва да стигне до route-а като параметър, както `presence`.

4. Рестартирай сървъра. Тест: `node test/ntfy.test.js` → `12 ntfy tests passed`.

Ако някой ден минеш на платен акаунт с APNs, двете работят едновременно:
APNs за тези с push token, ntfy за тези, които са го включили.
