# Промени по сървъра (за проблеми 2–4)

Твоите текущи сървърни файлове не съм ги виждал. Затова `presence.js` е пълен
файл (и е тестван), а за `server.js` и `validate.js` давам само конкретните
блокове за замяна.

## 1. `src/presence.js` — замени целия файл

Пусни теста с `node src/presence.test.js`. Очакван резултат: 7 passed.

## 2. `src/validate.js` — allow-list за contentType

Без тази промяна сървърът отговаря с **400** на receipts и профилите, а клиентът
не показва грешката никъде.

```js
const ALLOWED_CONTENT_TYPES = [
  'text', 'image', 'video', 'file',
  'notePad', 'receipt', 'profile', 'invite',
];
if (!ALLOWED_CONTENT_TYPES.includes(body.contentType)) return 'invalid contentType';
```

## 3. `server.js` — upgrade handler, след успешна автентикация

Замени частта след `const userId = resolveToken(store, msg.token)` /
`authenticated = true` с:

```js
      authenticated = true;
      presence.register(userId, conn);
      conn.sendText(JSON.stringify({ type: 'authOk', userId }));

      // Presence frames from the client. Attached *after* auth: the `once`
      // listener above consumed the auth frame, this one handles the rest.
      conn.on('message', (raw) => {
        let msg;
        try { msg = JSON.parse(raw); } catch { return; }
        if (msg?.type === 'contacts') {
          presence.setContacts(userId, msg.userIds);          // replies with a snapshot
        } else if (msg?.type === 'presenceState') {
          presence.setVisible(userId, msg.visible !== false); // foreground + opt-in
        }
      });

      heartbeat = setInterval(() => conn.ping(), HEARTBEAT_INTERVAL_MS);
      conn.on('close', () => clearInterval(heartbeat));
```

Не изпращай snapshot веднага след `authOk`, както предлагаше Pack 8. В този
момент клиентът още не е казал кои са контактите му, така че snapshot-ът би
бил винаги празен. Сега се праща в отговор на `contacts` фрейма.

`presence.register(...)` вече разпраща „offline“ при затваряне на връзката.
Ако имаш отделен `conn.on('close')`, който прави същото, махни го.

Рестартирай сървъра след промените.
