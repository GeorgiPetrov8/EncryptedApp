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
    func insert(_ message: Message, media: MediaItem?) throws {
        try dbQueue.write { db in
            try message.insert(db)
            try Self.insertMedia(db, media: media, message: message)
            try Self.touchConversation(db, message: message)
        }
    }

    /// Atomically stores an inbound message and marks its envelope processed (Bug #8).
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

    /// FIX (shared notepad): marks an envelope processed **without**
    /// inserting a `Message` row.
    ///
    /// A `.notePad` envelope's replay protection needs the exact same
    /// `processed_envelopes` dedup that chat messages already get (Bug #8) —
    /// the offline backfill queue and the live WebSocket stream can both
    /// redeliver the same envelope, and without this check a resent notepad
    /// op would simply re-merge harmlessly (the CRDT is idempotent) but
    /// still cost a wasted write and a spurious UI refresh on every replay.
    /// What it must *not* do is create a `Message` row: a notepad sync was
    /// never a chat message, and inserting one would put a phantom bubble
    /// in the conversation timeline with no corresponding user-visible
    /// content.
    ///
    /// Returns whether this call actually recorded the envelope as newly
    /// processed (`false` if it had already been seen) — `MessagingService`
    /// uses this the same way `insertIfNotProcessed`'s return value is
    /// used, to decide whether to publish a UI-refresh notification.
    @discardableResult
    func markEnvelopeProcessed(envelopeId: String, recipientUserId: String, senderId: String) throws -> Bool {
        try dbQueue.write { db in
            let alreadyProcessed = try ProcessedEnvelope
                .filter(Column("recipientUserId") == recipientUserId)
                .filter(Column("senderId") == senderId)
                .filter(Column("envelopeId") == envelopeId)
                .fetchCount(db) > 0
            guard !alreadyProcessed else { return false }

            try ProcessedEnvelope(
                recipientUserId: recipientUserId,
                senderId: senderId,
                envelopeId: envelopeId,
                receivedAt: Date()
            ).insert(db)
            return true
        }
    }

    /// Binds a media row to its parent message. The ids are set here rather
    /// than trusted from the caller, so the two rows cannot disagree.
    private static func insertMedia(_ db: Database, media: MediaItem?, message: Message) throws {
        guard var media else { return }
        media.messageId = message.id
        media.ownerUserId = message.ownerUserId
        try media.insert(db)
    }

    /// Maintains the denormalised ordering column in the same transaction as
    /// the insert, so the list can never disagree with the history (Bug #15).
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

    /// Scoped by owner: with ids shared across accounts, an update by `id`
    /// alone would flip the delivery status on the other account's copy.
    func updateDeliveryStatus(messageId: String, ownerUserId: String, status: DeliveryStatus) throws {
        try dbQueue.write { db in
            if var message = try Message.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId)) {
                message.deliveryStatus = status
                try message.update(db)
            }
        }
    }
    
    func markDelivered(
        messageId: String,
        ownerUserId: String,
        at date: Date
    ) throws {
        try dbQueue.write { db in
            guard var message = try Message.fetchOne(
                db,
                key: Self.key(ownerUserId: ownerUserId, id: messageId)
            ) else {
                return
            }

            message.deliveryStatus = .delivered
            message.deliveredAt = date
            try message.update(db)
        }
    }

    func markDelivered(
        messageIds: [String],
        ownerUserId: String,
        at date: Date
    ) throws {
        try dbQueue.write { db in
            for messageId in messageIds {
                guard var message = try Message.fetchOne(
                    db,
                    key: Self.key(ownerUserId: ownerUserId, id: messageId)
                ) else {
                    continue
                }

                message.deliveryStatus = .delivered
                message.deliveredAt = date
                try message.update(db)
            }
        }
    }

    func markRead(
        messageIds: [String],
        ownerUserId: String,
        at date: Date
    ) throws {
        try dbQueue.write { db in
            for messageId in messageIds {
                guard var message = try Message.fetchOne(
                    db,
                    key: Self.key(ownerUserId: ownerUserId, id: messageId)
                ) else {
                    continue
                }

                message.readAt = date
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
