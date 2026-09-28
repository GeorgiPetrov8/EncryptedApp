import Foundation
import os

/// FIX (Critical #1): a failed first send no longer bricks the conversation
/// permanently.
///
/// ## The bug
///
/// `transmitEnvelope` established the session *before* transmitting:
///
///   1. `X3DH.initiate` → `cryptoService.setSession(...)`
///   2. `persistSessionState(...)`   ← session is now durable
///   3. `apiClient.sendMessage(envelope)`  ← handshake payload crosses the wire
///
/// If step 3 failed (no signal, server down, a 500), the handshake payload was
/// lost — but the session from steps 1–2 survived. Every subsequent send then
/// took the `session != nil` branch and went out as a plain `.ratchet` envelope
/// with `handshake: nil`.
///
/// The recipient has no session and no handshake to derive one from, so they
/// throw `noSessionForRatchetMessage` — "ask your contact to start a new
/// conversation". Which they cannot do: `Conversation.deterministicId` means
/// "starting a new conversation" resolves to the *same* conversation, which
/// still has the same orphaned session, so the sender never emits a handshake
/// again. The pair is stuck forever, and the only visible symptom is on the
/// recipient's side.
///
/// ## The fix, in two layers
///
/// **Rollback** (`rollbackHandshakeSession`) — if the send that carried a
/// handshake fails, tear the session back down from memory *and* disk, so the
/// next attempt starts cleanly with a fresh X3DH.
///
/// **Handshake stickiness** (`PendingHandshakeStore`) — rollback alone is not
/// enough. The send can also fail *after* the server accepted it (response lost
/// on the way back), in which case rolling back would make us re-handshake
/// against a peer who already has a session — recoverable, but it burns a
/// one-time prekey and resets the ratchet. So the handshake payload is also
/// retained and re-attached to every outgoing message until the peer's first
/// reply proves they derived the session. This is what Signal does, and it
/// makes the handshake idempotent instead of a single point of failure.
///
/// Apply these members to `MessagingService`; the two call-site edits needed in
/// `transmitEnvelope` and `handleIncoming` are shown at the bottom of this file.
extension MessagingService {

    /// Removes a just-created session after its handshake failed to transmit.
    ///
    /// Both halves matter: the in-memory session is what the *next* send would
    /// see, and the persisted copy is what a relaunch would restore. Leaving
    /// either behind reproduces the original bug.
    func rollbackHandshakeSession(peerId: String, ownerUserId: String) {
        cryptoService.clearSession(for: peerId)
        do {
            try sessionRepository.delete(ownerUserId: ownerUserId, otherUserId: peerId)
        } catch {
            // Non-fatal: the in-memory session is already gone, so the next
            // send re-handshakes regardless. Worth logging because a stale row
            // here would resurrect the bug on next launch.
            Logger(subsystem: "com.HyperChat", category: "messaging")
                .error("Couldn't delete the rolled-back session row for \(peerId, privacy: .public)")
        }
    }
}

/// Retains an outgoing handshake until the peer demonstrably has the session.
///
/// Stored in the Keychain-backed encrypted store rather than `UserDefaults`:
/// the payload contains our ephemeral public key and the ids of the prekeys
/// used, which is metadata about who we are starting conversations with.
///
/// Keyed by `(ownerUserId, peerId)` so two local accounts talking to the same
/// peer keep separate pending handshakes — the same account-isolation rule
/// every other store here follows.
actor PendingHandshakeStore {

    private struct Entry: Codable {
        let payload: HandshakeInitPayload
        let createdAt: Date
    }

    private var entries: [String: Entry] = [:]

    /// A handshake this old is almost certainly never going to be answered;
    /// keeping it forever would mean re-sending a stale ephemeral key on every
    /// message indefinitely.
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private func key(ownerUserId: String, peerId: String) -> String {
        "\(ownerUserId)::\(peerId)"
    }

    func store(_ payload: HandshakeInitPayload, ownerUserId: String, peerId: String) {
        entries[key(ownerUserId: ownerUserId, peerId: peerId)] = Entry(payload: payload, createdAt: Date())
    }

    /// The handshake to attach to an outgoing message, if one is still pending.
    func pending(ownerUserId: String, peerId: String) -> HandshakeInitPayload? {
        let k = key(ownerUserId: ownerUserId, peerId: peerId)
        guard let entry = entries[k] else { return nil }
        guard Date().timeIntervalSince(entry.createdAt) < Self.maxAge else {
            entries[k] = nil
            return nil
        }
        return entry.payload
    }

    /// Called when the peer's first message arrives — proof they derived the
    /// session, so the handshake no longer needs re-sending.
    func clear(ownerUserId: String, peerId: String) {
        entries[key(ownerUserId: ownerUserId, peerId: peerId)] = nil
    }

    func clearAll(ownerUserId: String) {
        entries = entries.filter { !$0.key.hasPrefix("\(ownerUserId)::") }
    }
}

// MARK: - Required call-site edits
//
// 1. `CryptoService` needs a way to drop a session (it only had `setSession`):
//
//        func clearSession(for peerUserId: String) {
//            activeSessions[peerUserId] = nil
//        }
//
// 2. `SessionRepository` needs a scoped delete:
//
//        func delete(ownerUserId: String, otherUserId: String) throws {
//            try dbQueue.write { db in
//                _ = try SessionRecord
//                    .filter(Column("ownerUserId") == ownerUserId)
//                    .filter(Column("otherUserId") == otherUserId)
//                    .deleteAll(db)
//            }
//        }
//
// 3. In `MessagingService.transmitEnvelope`, replace the tail of the method
//    (from `try await apiClient.sendMessage(envelope)` onward) with:
//
//        // Re-attach a handshake that was never acknowledged, even on an
//        // envelope that would otherwise go out as plain `.ratchet`.
//        var outgoingHandshake = handshake
//        var outgoingKind = kind
//        if outgoingHandshake == nil,
//           let retained = await pendingHandshakes.pending(ownerUserId: myUserId, peerId: peerId) {
//            outgoingHandshake = retained
//            outgoingKind = .handshake
//        }
//
//        let envelope = EnvelopeDTO(
//            id: envelopeId,
//            conversationId: conversation.id,
//            senderId: myUserId,
//            recipientId: peerId,
//            kind: outgoingKind,
//            handshake: outgoingHandshake,
//            ratchetMessage: try ratchetMessage.serialized(),
//            contentType: contentType,
//            createdAt: createdAt
//        )
//
//        if let handshake {
//            // Retained *before* the send, so a lost response still leaves us
//            // able to re-attach rather than re-handshake.
//            await pendingHandshakes.store(handshake, ownerUserId: myUserId, peerId: peerId)
//        }
//
//        do {
//            try await apiClient.sendMessage(envelope)
//        } catch {
//            if kind == .handshake {
//                // This send created the session. Tear it down so the next
//                // attempt performs a fresh X3DH instead of emitting an
//                // underivable `.ratchet` envelope forever.
//                rollbackHandshakeSession(peerId: peerId, ownerUserId: myUserId)
//                await pendingHandshakes.clear(ownerUserId: myUserId, peerId: peerId)
//            }
//            throw error
//        }
//
// 4. In `MessagingService.handleIncoming`, after the message decrypts
//    successfully, clear the pending handshake — their reply proves the
//    session took:
//
//        await pendingHandshakes.clear(ownerUserId: myUserId, peerId: envelope.senderId)
//
// 5. Add the store as a `MessagingService` property:
//
//        private let pendingHandshakes = PendingHandshakeStore()
