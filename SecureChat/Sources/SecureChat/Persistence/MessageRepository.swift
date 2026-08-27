import Foundation
import GRDB

final class MessageRepository {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    func insert(_ message: Message) throws {
        try dbQueue.write { db in try message.insert(db) }
    }

    /// FIX (Bug #8): atomically stores an inbound message *and* marks its envelope
    /// as processed.
    ///
    /// These have to share one transaction. The original plan of "record the id in
    /// the same transaction as the insert" was not achievable from `MessagingService`,
    /// because `insert` opened its own `dbQueue.write` — a crash between the two
    /// writes would leave the message stored but the envelope unmarked (so a redelivery
    /// would advance the ratchet again), or the reverse.
    ///
    /// Returns `false` when the envelope was already processed, in which case nothing
    /// is written. The uniqueness check happens inside the transaction, so two
    /// concurrent deliveries of the same envelope cannot both pass it.
    @discardableResult
    func insertIfNotProcessed(
        _ message: Message,
        envelopeId: String,
        recipientUserId: String,
        senderId: String
    ) throws -> Bool {
        try dbQueue.write { db in
            let alreadyProcessed = try ProcessedEnvelope
                .filter(Column("recipientUserId") == recipientUserId)
                .filter(Column("senderId") == senderId)
                .filter(Column("envelopeId") == envelopeId)
                .fetchCount(db) > 0

            guard !alreadyProcessed else { return false }

            try message.insert(db)
            try ProcessedEnvelope(
                recipientUserId: recipientUserId,
                senderId: senderId,
                envelopeId: envelopeId,
                receivedAt: Date()
            ).insert(db)
            return true
        }
    }

    /// FIX (Bug #8): cheap pre-check before touching the ratchet at all.
    ///
    /// This is the check that actually prevents the damage. Decrypting a replayed
    /// envelope advances `receivingChainKey` and persists the mutated session, and
    /// only *then* did the old code hit a primary-key conflict on insert — which
    /// `try?` in `startListening` swallowed. The session was left mutated, the
    /// message never appeared, and nothing was logged.
    func isEnvelopeProcessed(envelopeId: String, recipientUserId: String, senderId: String) throws -> Bool {
        try dbQueue.read { db in
            try ProcessedEnvelope
                .filter(Column("recipientUserId") == recipientUserId)
                .filter(Column("senderId") == senderId)
                .filter(Column("envelopeId") == envelopeId)
                .fetchCount(db) > 0
        }
    }

    /// FIX (Bug #8): housekeeping so the dedup table doesn't grow without bound.
    func pruneProcessedEnvelopes(olderThan interval: TimeInterval = 30 * 24 * 60 * 60) throws {
        let cutoff = Date().addingTimeInterval(-interval)
        try dbQueue.write { db in
            try ProcessedEnvelope.filter(Column("receivedAt") < cutoff).deleteAll(db)
        }
    }

    func updateDeliveryStatus(messageId: String, status: DeliveryStatus) throws {
        try dbQueue.write { db in
            if var message = try Message.fetchOne(db, key: messageId) {
                message.deliveryStatus = status
                try message.update(db)
            }
        }
    }

    /// FIX (Bug #10): scoped to the owning account.
    func fetchMessages(conversationId: String, ownerUserId: String) throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("conversationId") == conversationId)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    func latestMessage(conversationId: String, ownerUserId: String) throws -> Message? {
        try dbQueue.read { db in
            try Message
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("conversationId") == conversationId)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    /// FIX (Bug #10): used by `deleteAccount` — the only path that destroys data.
    func deleteAll(ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try Message.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
            _ = try ProcessedEnvelope.filter(Column("recipientUserId") == ownerUserId).deleteAll(db)
        }
    }
}
