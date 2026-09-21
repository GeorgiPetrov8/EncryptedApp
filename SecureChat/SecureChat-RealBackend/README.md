# SecureChat — истинска комуникация между устройства

Отговор на четирите точки, плюс работещ код за всяка.

## Съдържание на пакета

```
SecureChat-RealBackend/
├── SecureChatServer/                    ← т.1, т.2: истински бекенд + истинска база
│   ├── server.js, src/*.js               (виж SecureChatServer/README.md за пълни детайли)
│   ├── Dockerfile, docker-compose.yml, Caddyfile   ← т.4: TLS
│   ├── test/smoke.js                     (19 теста, РЕАЛНО пуснати и минаващи)
│   └── package.json                      (ZERO зависимости — виж по-долу защо)
└── SecureChatClient-Additions/          ← т.3: мрежов слой на клиента
    ├── Networking/
    │   ├── NetworkConfiguration.swift    (base URL + JSON coding правила)
    │   ├── SessionTokenStore.swift       (bearer token, отделен от AuthService)
    │   ├── RealAPIClient.swift           (APIClientProtocol през URLSession)
    │   └── RealWebSocketService.swift    (WebSocketServiceProtocol през URLSessionWebSocketTask)
    ├── Services/
    │   ├── AuthService.swift             (заменя — добавя token storage)
    │   └── AppContainer.swift            (заменя — избира Mock/Real)
    └── project.yml                       (заменя — API_BASE_URL, ATS, нова схема)
```

## Важна бележка за средата, в която е писано това

Нямам достъп до Swift/Vapor тук, нито до интернет за `npm install`. Затова
избрах **Node.js с вградения `node:sqlite`** (стабилен от Node 22.5, тук на
Node 24) — истинска, durable, файлова база данни, **нула** трети страни
пакети. Разлика от целия предишен Swift код в тази конверсация: **това
реално го пуснах и тествах** — 19 end-to-end теста, включително истинско
WebSocket ръкостискане между вградения WebSocket клиент на Node и
собствения ми RFC 6455 сървър, изпращане/получаване на съобщения,
изчерпване и презареждане на one-time prekey пула, ротация на signed
prekey, offline опашка, replay защита, media round-trip и rate limiting.
Проверих и durability през рестарт на процеса (регистрирах акаунт, спрях
процеса, стартирах нов процес, логнах се успешно — данните са на диск, не
в паметта).

Ако предпочиташ Vapor (Swift) вместо Node — архитектурата на протокола е
идентична (същите route-ове, същите DTO полета), само транспортният слой
се пренаписва; кажи ми и ще го направя, но нямаше да мога да го компилирам
тук, за разлика от това, което получаваш сега.

---

## 1. Истински бекенд

`SecureChatServer/` имплементира всеки route, който `APIClientProtocol`
изисква:

| Клиентски метод | Route |
|---|---|
| `register` | `POST /auth/register` |
| `login` | `POST /auth/login` |
| `replenishOneTimePreKeys` | `POST /prekeys/one-time` |
| `publishSignedPreKey` | `POST /prekeys/signed` |
| `fetchDirectoryEntry` | `GET /directory/by-id/:id`, `by-username/:name` |
| `fetchPreKeyBundle` | `GET /bundles/by-id/:id`, `by-username/:name` |
| `sendMessage` | `POST /messages` |
| `fetchPendingEnvelopes` | `GET /messages/pending?since=N` |
| `fetchEnvelopes` | `GET /messages?conversationId=` |
| `acknowledge` | `POST /messages/ack` |
| `uploadMedia` / `downloadMedia` | `POST /media`, `GET /media/:id` |

Плюс `GET /ws` за WebSocket upgrade — ръчна имплементация на RFC 6455
(handshake + frame кодек), защото пакетът `ws` не можеше да се инсталира
офлайн. Автентикацията минава като **първо съобщение** след connect
(`{"type":"auth","token":"..."}`), не като `?token=` в URL-а — токен в URL
влиза в access log-овете на всеки прокси по подразбиране; токен като WS
frame върху вече TLS-защитена връзка — не.

**Durable опашка per recipient** (`pending_envelopes` таблица) — точно
логиката, която `MockBackendStore.pendingByRecipient` симулираше в паметта,
сега на диск. **One-time prekey pool management** — `popOneTimePreKey`
прави `DELETE ... RETURNING` атомарно, така че двама конкурентни клиенти
никога не получават един и същ prekey (тествано изрично).

**Умишлена разлика от Mock:** сървърът не пази перманентен архив по
разговор — `MockBackendStore.envelopesByConversation` държеше всичко
завинаги; тук редът се трие при acknowledge. Сървърът релейва, не архивира
— клиентът вече си пази декриптираната история локално, а перманентен
архив на ciphertext на сървъра е чист риск без полза.

## 2. Истинска база данни

SQLite (`node:sqlite`, вграден в Node, SQLite 3.53 с `RETURNING` clause) —
**не** Swift `Dictionary` в паметта. WAL режим за конкурентен достъп,
`PRAGMA foreign_keys = ON`, реални транзакции. Проверих durability-то на
живо (виж по-горе).

**Защо не Postgres направо:** нулева операционна зависимост за скелет —
`docker compose up` и работи. Пътят към Postgres е документиран в
`docker-compose.yml` (закоментиран service) и в `SecureChatServer/README.md`
— смяната е ограничена изцяло до `src/db.js`; `server.js` и route
хендлърите викат само `store.stmt.*`, нищо SQLite-специфично извън този
файл.

## 3. Мрежов слой на клиента

`SecureChatClient-Additions/Networking/`:

- **`RealAPIClient`** — имплементира `APIClientProtocol` през `URLSession`.
- **`RealWebSocketService`** — имплементира `WebSocketServiceProtocol` през
  `URLSessionWebSocketTask`, с auto-reconnect (exponential backoff, капнат
  на 30s) и auth-first-frame, огледално на сървъра.
- **`SessionTokenStore`** — държи bearer token-а в Keychain, **отделно** от
  `AuthService`. Причината: `AuthService`-ият инициализатор вече взима
  `apiClient` (за да вика register/login) — значи `apiClient` трябва да
  съществува преди `AuthService`. Но `RealAPIClient` има нужда от текущия
  token за всяко друго повикване. `SessionTokenStore` е независимата точка,
  която строи `AppContainer` **първо**, и я подава на двете страни — без
  кръгова зависимост.
- **`NetworkConfiguration`** — `baseURL`/`useMockBackend`, четени с
  приоритет: environment variable (бърза смяна без rebuild) → Info.plist
  key (per-scheme стойност от `project.yml`) → localhost fallback.

**Намерен и оправен реален bug при писането:** Swift-овата `.iso8601` date
стратегия по подразбиране **не** парсва милисекунди, а Node-овият
`toISOString()` винаги ги праща (`"...12:00:00.000Z"`). С default
стратегията декодирането щеше да гърми при първия реален request — нещо,
което не можеше да се хване, четейки Swift кода изолирано, само чрез
реален сървър отсреща. `SecureChatJSON` в `NetworkConfiguration.swift`
използва custom `ISO8601DateFormatter` с `.withFractionalSeconds`, с
fallback без тях.

### Как да включиш реалния бекенд

1. Копирай файловете от `SecureChatClient-Additions/` в съответните папки
   на Xcode проекта (`Networking/`, `Services/`), замествайки старите
   `AuthService.swift` и `AppContainer.swift`.
2. Замести `project.yml` с версията тук (или merge-ни ръчно — добавя
   `API_BASE_URL`/`USE_MOCK_BACKEND` per-config, ATS изключение за local
   network, и нова схема `SecureChat-Mock`).
3. `xcodegen generate`.
4. Пусни сървъра: `cd SecureChatServer && npm start` (виж
   `SecureChatServer/README.md`).
5. Пусни приложението със схема **SecureChat** (реален бекенд,
   `http://127.0.0.1:8080` в Debug) или **SecureChat-Mock** (стария
   in-memory мок, ако ти трябва за UI работа без сървър).

За тест от истинско устройство (не симулатор): смени `API_BASE_URL` в
Debug конфигурацията на LAN IP-то на твоя Мак (`http://192.168.x.x:8080`)
вместо `127.0.0.1` — устройството не е same machine като loopback-а.

## 4. TLS, rate limiting, abuse protection

- **TLS:** `docker-compose.yml` включва Caddy пред сървъра — automatic
  HTTPS през Let's Encrypt, само с DNS насочен към машината. Смени
  `chat.yourdomain.example` в `Caddyfile` с реалния домейн. Node процесът
  сам никога не гледа навън — само Caddy на 80/443.
- **Rate limiting:** in-memory sliding-window per IP, по-строг за
  auth/prekey endpoint-и (10/min) отколкото за съобщения (120/min) — виж
  `src/rateLimit.js`. Тестван изрично (`auth rate limit engages`). Ограничение:
  per-process, не споделено между инстанции — документирано в
  `SecureChatServer/README.md` заедно с Redis пътя за истинско хоризонтално
  скалиране.
- **Abuse protection:** валидация на размера на всяко ключово поле
  (X25519/Ed25519 точно 32/64 байта) **преди** запис в базата — спира
  storage-bloat атака с фалшиви "ключове"; таван на размера на ratchet
  payload (256 KiB) и media upload (25 MiB); опашка envelope-и капната на
  200 на страница; opaque bearer tokens (SHA-256 hash в базата, не суров
  токен — ако `sessions` изтече, токените не са directly reusable);
  автентикация за всеки non-register/login route.

---

## Какво остава

- `ChatView` още няма photo picker (отделен, известен пропуск от преди) —
  media route-овете на сървъра са готови и тествани, чакат UI кука.
- Ако минеш на повече от една инстанция на сървъра — presence и rate
  limiting трябва Redis (документирано, не имплементирано — извън обхвата
  на "минимален реален бекенд").
- Крипто слоят (X3DH/Double Ratchet) остава непроменен и неодитиран — това
  добавя транспорт, не пипа протокола.
