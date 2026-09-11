import Foundation
import GRDB

final class MessageRepository {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    private static func key(ownerUserId: String, id: String) -> [String: DatabaseValueConvertible] {
        ["ownerUserId": ownerUserId, "id": id]
    }

    func insert(_ message: Message) throws {
        try dbQueue.write { db in try message.insert(db) }
    }

    /// Message and its media row in one transaction (Bug #13).
    ///
    /// The media table has a composite foreign key to `messages(ownerUserId, id)`, so
    /// the message must exist first. Doing the two inserts as separate `dbQueue.write`
    /// blocks would allow a message with a dangling attachment, or an orphan media row,
    /// if the process died in between.
    func insert(_ message: Message, media: MediaItem?) throws {
        try dbQueue.write { db in
            try message.insert(db)
            try Self.insertMedia(db, media: media, message: message)
            try Self.touchConversation(db, message: message)
        }
    }

    /// Atomically stores an inbound message and marks its envelope processed (Bug #8).
    ///
    /// FIX: gained a `media` parameter.
    ///
    /// Without it the receiving side had no way to persist a `MediaItem` at all —
    /// `MediaItem(...)` was constructed in exactly one place in the project,
    /// `prepareForSending`, which only ever runs on the sender. A received photo
    /// produced a `Message` row with `contentType: .image` and nothing else.
    ///
    /// Display still worked, because the per-file key travels inside the message
    /// payload rather than through this table. What broke was ownership: the
    /// recipient's cached blob was referenced by no row, so
    /// `exclusivelyOwnedPaths` would report the sender as the only owner and delete
    /// the shared file out from under the recipient — the precise scenario the
    /// composite key was introduced to handle. A media gallery built on
    /// `fetchAll(ownerUserId:)` would likewise have shown sent attachments only.
    @discardableResult
    func insertIfNotProcessed(
        _ message: Message,
        media: MediaItem? = nil,
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
            try Self.insertMedia(db, media: media, message: message)
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

    /// Binds a media row to its parent message. The ids are set here rather than
    /// trusted from the caller, so the two rows cannot disagree.
    private static func insertMedia(_ db: Database, media: MediaItem?, message: Message) throws {
        guard var media else { return }
        media.messageId = message.id
        media.ownerUserId = message.ownerUserId
        try media.insert(db)
    }

    /// Maintains the denormalised ordering column in the same transaction as the
    /// insert, so the list can never disagree with the history (Bug #15).
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

    /// Scoped by owner: with ids shared across accounts, an update by `id` alone would
    /// flip the delivery status on the other account's copy.
    func updateDeliveryStatus(messageId: String, ownerUserId: String, status: DeliveryStatus) throws {
        try dbQueue.write { db in
            if var message = try Message.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId)) {
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
