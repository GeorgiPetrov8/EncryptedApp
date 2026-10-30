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

    func insert(_ message: Message, media: MediaItem?) throws {
        try dbQueue.write { db in
            try message.insert(db)
            try Self.insertMedia(db, media: media, message: message)
            try Self.touchConversation(db, message: message)
        }
    }

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
                guard var message = try Message.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId)) else { continue }
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
                guard var message = try Message.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId)) else { continue }
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

    func updateContent(messageId: String, ownerUserId: String, encryptedContent: Data, editedAt: Date) throws {
        try dbQueue.write { db in
            guard var message = try Message.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId)) else { return }
            message.encryptedContent = encryptedContent
            message.editedAt = editedAt
            try message.update(db)
        }
    }

    func delete(messageId: String, ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try Message.deleteOne(db, key: Self.key(ownerUserId: ownerUserId, id: messageId))
        }
    }

    // MARK: Reactions

    @discardableResult
    func upsertReactionIfNewer(_ reaction: MessageReaction) throws -> Bool {
        try dbQueue.write { db in
            guard try Message.fetchOne(
                db, key: Self.key(ownerUserId: reaction.ownerUserId, id: reaction.messageId)
            ) != nil else { return false }

            let reactionKey: [String: DatabaseValueConvertible] = [
                "ownerUserId": reaction.ownerUserId,
                "messageId": reaction.messageId,
                "reactorId": reaction.reactorId,
            ]
            if let existing = try MessageReaction.fetchOne(db, key: reactionKey),
               existing.updatedAt >= reaction.updatedAt {
                return false
            }
            try reaction.save(db)
            return true
        }
    }

    func fetchReactions(conversationId: String, ownerUserId: String) throws -> [MessageReaction] {
        try dbQueue.read { db in
            try MessageReaction
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("conversationId") == conversationId)
                .fetchAll(db)
        }
    }

    /// Reactions for specific messages only (the loaded page).
    func fetchReactions(messageIds: [String], ownerUserId: String) throws -> [MessageReaction] {
        guard !messageIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            try MessageReaction
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(messageIds.contains(Column("messageId")))
                .fetchAll(db)
        }
    }

    // MARK: Queries

    /// Whole conversation, oldest first. Used by sending/backup — not by the chat
    /// screen any more (see `fetchRecentMessages`).
    func fetchMessages(conversationId: String, ownerUserId: String) throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("conversationId") == conversationId)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    /// NEW (R25): the newest `limit` messages, returned oldest first.
    func fetchRecentMessages(conversationId: String, ownerUserId: String, limit: Int) throws -> [Message] {
        try dbQueue.read { db in
            let newestFirst = try Message
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("conversationId") == conversationId)
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
            return Array(newestFirst.reversed())
        }
    }

    /// NEW (R25): how many messages the conversation has.
    func countMessages(conversationId: String, ownerUserId: String) throws -> Int {
        try dbQueue.read { db in
            try Message
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("conversationId") == conversationId)
                .fetchCount(db)
        }
    }

    /// NEW (media backup): every message of the account that carries media.
    func fetchMediaMessages(ownerUserId: String) throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("contentType") != MessageContentType.text.rawValue)
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
            _ = try MessageReaction.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
            _ = try Message.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
            _ = try ProcessedEnvelope.filter(Column("recipientUserId") == ownerUserId).deleteAll(db)
        }
    }
}
