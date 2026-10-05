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

    /// Marks an envelope processed without inserting a `Message` row
    /// (control messages: pad, receipts, profile, invite, call, edit).
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

    private static func insertMedia(_ db: Database, media: MediaItem?, message: Message) throws {
        guard var media else { return }
        media.messageId = message.id
        media.ownerUserId = message.ownerUserId
        try media.insert(db)
    }

    private static func touchConversation(_ db: Database, message: Message) throws {
        try db.execute(sql: """
            UPDATE conversations
            SET lastMessageAt = ?
            WHERE id = ? AND ownerUserId = ?
              AND (lastMessageAt IS NULL OR lastMessageAt < ?)
            """, arguments: [message.createdAt, message.conversationId, message.ownerUserId, message.createdAt])
    }

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

    func updateDeliveryStatus(messageId: String, ownerUserId: String, status: DeliveryStatus) throws {
        try dbQueue.write { db in
            if var message = try Message.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId)) {
                message.deliveryStatus = status
                try message.update(db)
            }
        }
    }

    func markDelivered(messageId: String, ownerUserId: String, at date: Date) throws {
        try markDelivered(messageIds: [messageId], ownerUserId: ownerUserId, at: date)
    }

    func markDelivered(messageIds: [String], ownerUserId: String, at date: Date) throws {
        guard !messageIds.isEmpty else { return }
        try dbQueue.write { db in
            for messageId in messageIds {
                guard var message = try Message.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId)) else {
                    continue
                }
                message.deliveryStatus = .delivered
                message.deliveredAt = date
                try message.update(db)
            }
        }
    }

    func markRead(messageIds: [String], ownerUserId: String, at date: Date) throws {
        guard !messageIds.isEmpty else { return }
        try dbQueue.write { db in
            for messageId in messageIds {
                guard var message = try Message.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId)) else {
                    continue
                }
                message.readAt = date
                try message.update(db)
            }
        }
    }

    // MARK: Edit / delete

    func fetch(messageId: String, ownerUserId: String) throws -> Message? {
        try dbQueue.read { db in
            try Message.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId))
        }
    }

    /// Replaces a message's stored (storage-key-encrypted) content after an edit.
    func updateContent(messageId: String, ownerUserId: String, encryptedContent: Data, editedAt: Date) throws {
        try dbQueue.write { db in
            guard var message = try Message.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId)) else {
                return
            }
            message.encryptedContent = encryptedContent
            message.editedAt = editedAt
            try message.update(db)
        }
    }

    /// "Delete for me". The media row goes with it via the foreign-key cascade.
    func delete(messageId: String, ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try Message.deleteOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId))
        }
    }

    // MARK: Queries

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
