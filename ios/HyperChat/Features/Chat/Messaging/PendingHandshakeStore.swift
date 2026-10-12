import Foundation
import os

/// Retains an outgoing X3DH handshake until the peer demonstrably has the
/// session (their first reply decrypts).
///
/// FIX (Pack 8, Critical #1): part of the handshake-rollback fix — see
/// `MessagingService.transmitEnvelope`.
///
/// Persisted in the Keychain, not held in memory as Pack 8's draft `actor`
/// did. An in-memory store is empty after a relaunch, and "the send's response
/// was lost, then the app was killed" is exactly the case this store exists
/// for: the session survives on disk, the handshake would not, and every later
/// message would again go out as an underivable `.ratchet` envelope.
///
/// Keyed by `(ownerUserId, peerId)` through `KeychainStore.namespaced`, so two
/// local accounts keep separate pending handshakes and `clearAll` can remove
/// one account's entries with `deleteAll(forUserId:)`.
@MainActor
final class PendingHandshakeStore {
    private struct Entry: Codable {
        let payload: HandshakeInitPayload
        let createdAt: Date
    }

    private let keychain: KeychainStore
    private let logger = Logger(subsystem: "com.HyperChat", category: "messaging")

    /// A handshake this old is almost certainly never going to be answered;
    /// keeping it forever would re-send a stale ephemeral key indefinitely.
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    init(keychain: KeychainStore = KeychainStore(service: "com.HyperChat.pendingHandshakes")) {
        self.keychain = keychain
    }

    private func key(ownerUserId: String, peerId: String) -> String {
        KeychainStore.namespaced("pendingHandshake.\(peerId)", userId: ownerUserId)
    }

    func store(_ payload: HandshakeInitPayload, ownerUserId: String, peerId: String) {
        do {
            let data = try JSONEncoder().encode(Entry(payload: payload, createdAt: Date()))
            try keychain.save(key: key(ownerUserId: ownerUserId, peerId: peerId), data: data)
        } catch {
            logger.error("Couldn't persist pending handshake for \(peerId, privacy: .public)")
        }
    }

    /// The handshake to attach to an outgoing message, if one is still pending.
    func pending(ownerUserId: String, peerId: String) -> HandshakeInitPayload? {
        let k = key(ownerUserId: ownerUserId, peerId: peerId)
        guard let data = keychain.loadIfPresent(key: k),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }

        guard Date().timeIntervalSince(entry.createdAt) < Self.maxAge else {
            keychain.delete(key: k)
            return nil
        }
        return entry.payload
    }

    /// Called when the peer's first message decrypts — proof they derived the
    /// session, so the handshake no longer needs re-sending.
    func clear(ownerUserId: String, peerId: String) {
        keychain.delete(key: key(ownerUserId: ownerUserId, peerId: peerId))
    }

    func clearAll(ownerUserId: String) {
        keychain.deleteAll(forUserId: ownerUserId)
    }
}
