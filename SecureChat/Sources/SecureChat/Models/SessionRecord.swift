import Foundation
import GRDB

/// Persisted Double Ratchet session state for one peer. `encryptedState` is
/// a JSON-serialized `RatchetSessionState` (see DoubleRatchet.swift),
/// encrypted at rest with the local storage key before being written here.
struct SessionRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"

    var id: String
    /// FIX (Bug #10): which local account owns this session.
    ///
    /// `otherUserId` used to be globally `UNIQUE`, so two accounts on the same device
    /// talking to the same peer would fight over a single row — and each would try to
    /// decrypt the other's state with its own storage key. The uniqueness constraint
    /// is now `(ownerUserId, otherUserId)`.
    var ownerUserId: String
    var otherUserId: String
    var encryptedState: Data
    var createdAt: Date
    var updatedAt: Date
}

/// FIX (Bug #8): records envelopes that have already been fully processed.
///
/// The primary key is `(recipientUserId, senderId, envelopeId)`, not the envelope id
/// alone. Envelope ids are chosen by the *sender* (`localMessageId` in
/// `MessagingService.send`), so a globally unique key would let one peer pick an id
/// that collides with another peer's message and suppress it.
struct ProcessedEnvelope: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "processed_envelopes"

    var recipientUserId: String
    var senderId: String
    var envelopeId: String
    var receivedAt: Date
}
