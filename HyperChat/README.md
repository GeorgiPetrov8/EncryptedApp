# HyperChat (scaffold)

An end-to-end encrypted messaging app scaffold for iOS: SwiftUI, a from-scratch
X3DH + Double Ratchet crypto layer built on CryptoKit, a GRDB-backed local
database with application-level encryption at rest, and an in-memory mock
backend + WebSocket so the whole flow (register → handshake → chat) runs
without standing up a real server.

## ⚠️ Read this first

- **This has not been compiled.** It was written in a Linux sandbox with no
  Xcode or iOS SDK, so nothing here has been build-verified. Expect to fix a
  handful of small issues (an import, a type inference hiccup, an API name
  drift between CryptoKit/GRDB versions) on first build in Xcode. The
  architecture and crypto flow have been traced through by hand line-by-line,
  but only a real compiler and test run can catch everything.
- **The crypto is hand-rolled, not audited.** X3DH and Double Ratchet here
  follow the published algorithm shapes as a learning/scaffold reference, not
  a security-reviewed implementation. For anything beyond a prototype, prefer
  a vetted library (e.g. libsignal) over hand-rolled protocol code.
- **What's *not* built**, per the original spec's own "optional/advanced"
  sections: group messaging (TreeKEM), voice/video calls (WebRTC/ZRTP),
  private contact discovery (PSI), a real backend server, disappearing
  messages, multi-device sync, and App Store compliance paperwork.
  **Text messaging is the fully wired path** (register → handshake → send →
  receive → persisted, decrypted history in the chat UI). `MediaEncryptionService`
  implements the encrypt/upload/download/decrypt logic for images at the
  service layer, but there's no photo-picker button in `ChatView` yet to
  trigger it — wiring that up is a good next step (see "Next steps" below).

## What's implemented

| Area | Where |
|---|---|
| X3DH handshake | `Crypto/X3DH.swift` |
| Double Ratchet (forward secrecy, out-of-order delivery) | `Crypto/DoubleRatchet.swift` |
| AES-256-GCM, PBKDF2, Keychain storage | `Crypto/AESGCM.swift`, `Crypto/KeychainStore.swift` |
| Local encrypted DB (GRDB + Data Protection + app-level AES) | `Persistence/` |
| Mock backend + mock WebSocket (zero-knowledge: ciphertext only) | `Networking/` |
| Auth, messaging orchestration, media encryption, app lock | `Services/` |
| SwiftUI screens: login/register, chat list, chat, settings, app lock | `Views/` |
| Crypto round-trip unit tests | `Tests/HyperChatTests/CryptoTests.swift` |

### A deliberate design change from the original spec

The spec's schema comment says `messages.encrypted_content` — but Double
Ratchet message keys are used once and discarded (that's what gives forward
secrecy its teeth), so they *can't* be used to re-decrypt history later. This
project instead:
- encrypts in transit with the Double Ratchet (network envelopes only),
- stores message history encrypted at rest with a separate, persistent
  local storage key (`CryptoService.encryptForStorage`).

This mirrors how Signal's own client actually handles local history, and it's
called out explicitly in `Models/Message.swift`.

The spec also calls for SQLCipher (whole-database encryption). That needs a
custom OpenSSL-linked SQLite build, which is a heavy dependency for a
scaffold. Instead this project layers iOS Data Protection on the database
file itself with application-level AES-GCM on every sensitive column — see
the note in `Persistence/DatabaseManager.swift` for how to swap in SQLCipher
later if you need whole-file encryption too.

## Setup

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
2. From this folder: `xcodegen generate`
3. `open HyperChat.xcodeproj`
4. Let Xcode resolve the GRDB Swift Package (Signing & Capabilities may also
   prompt you to pick a team — any personal team works for simulator builds).
5. Signing & Capabilities → enable **Data Protection** on the `HyperChat`
   target (needed for the `NSFileProtectionCompleteUntilFirstUserAuthentication`
   setting on the local database file to take effect).
6. Build & run on a simulator or device (iOS 16+).
7. To try messaging between two accounts: run the app in two simulators (or
   simulator + device), register a different username in each — they share
   the same in-memory mock backend only if run in the *same process*, so for
   real two-way testing, register two accounts in one app run using the
   in-app flow, log out, and log the second one in, or extend `MockAPIClient`
   into a tiny local HTTP server if you want genuinely separate app instances
   to talk to each other.

## Running tests

`Cmd+U` in Xcode, or:
```
xcodebuild test -project HyperChat.xcodeproj -scheme HyperChat -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Next steps if you take this further

- Add a photo-picker button to `ChatView`'s input bar (`PHPickerViewController`
  via `UIViewControllerRepresentable`) that calls
  `MediaEncryptionService.prepareForSending` and sends the resulting payload
  through `MessagingService.send(plaintext:contentType:in:)` with
  `contentType: .image` — the encryption/upload/download/decrypt logic is
  already there, it just isn't triggered from the UI yet.
- Swap `MockAPIClient`/`MockWebSocketService` for real `URLSession`/
  `URLSessionWebSocketTask` implementations against an actual backend —
  `APIClientProtocol` and `WebSocketServiceProtocol` are the seams.
- Add video capture/playback (the spec's chunked-upload + `AVPlayer`
  streaming plan) — `MediaEncryptionService` currently handles single-blob
  image encryption only.
- Independent security review of the crypto layer before any real use.
- Certificate pinning, App Store Encryption Export Compliance declaration,
  and a privacy policy before shipping anywhere.
