import Foundation
import GRDB

final class MessageRepository {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    func insert(_ message: Message) throws {
        try dbQueue.write { db in try message.insert(db) }
    }

    /// FIX (Bug #13): message and its media row in one transaction.
    ///
    /// The media table has a `NOT NULL` foreign key to `messages(id)`, so the message
    /// must exist first. Doing the two inserts as separate `dbQueue.write` blocks
    /// would allow a message with a dangling attachment (or an orphan media row) if
    /// the process died in between.
    ///
    /// `media.messageId` is set here rather than trusted from the caller, so the two
    /// rows can't disagree.
    func insert(_ message: Message, media: MediaItem?) throws {
        try dbQueue.write { db in
            try message.insert(db)
            if var media {
                media.messageId = message.id
                media.ownerUserId = message.ownerUserId
                try media.insert(db)
            }
            try Self.touchConversation(db, message: message)
        }
    }

    /// Atomically stores an inbound message and marks its envelope processed (Bug #8).
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
            try Self.touchConversation(db, message: message)
            return true
        }
    }

    /// FIX (Bug #15): maintains the denormalised ordering column in the same
    /// transaction as the insert, so the list can never disagree with the history.
    private static func touchConversation(_ db: Database, message: Message) throws {
        try db.execute(sql: """
            UPDATE conversations
            SET lastMessageAt = ?
            WHERE id = ? AND ownerUserId = ?
              AND (lastMessageAt IS NULL OR lastMessageAt < ?)
            """, arguments: [message.createdAt, message.conversationId, message.ownerUserId, message.createdAt])
    }

    /// Cheap pre-check before touching the ratchet at all (Bug #8).
    func isEnvelopeProcessed(envelopeId: String, recipientUserId: String, senderId: String) throws -> Bool {
        try dbQueue.read { db in
            try ProcessedEnvelope
                .filter(Column("recipientUserId") == recipientUserId)
                .filter(Column("senderId") == senderId)
                .filter(Column("envelopeId") == envelopeId)
                .fetchCount(db) > 0
        }
    }

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

    func deleteAll(ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try Message.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
            _ = try ProcessedEnvelope.filter(Column("recipientUserId") == ownerUserId).deleteAll(db)
        }
    }
}
