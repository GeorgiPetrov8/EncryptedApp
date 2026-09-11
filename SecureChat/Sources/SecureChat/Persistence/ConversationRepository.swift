import Foundation
import GRDB

/// Every read and write is scoped to the owning account (Bug #10).
final class ConversationRepository {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    private static func key(ownerUserId: String, id: String) -> [String: DatabaseValueConvertible] {
        ["ownerUserId": ownerUserId, "id": id]
    }

    /// FIX: safe now that the primary key is `(ownerUserId, id)`.
    ///
    /// `save(db)` resolves to an UPDATE on primary-key match. While the key was `id`
    /// alone and Bug #14 made conversation ids identical across accounts, the
    /// recipient's save matched the *sender's* row and rewrote its `ownerUserId` —
    /// the conversation silently disappeared from the sender's list. The composite key
    /// makes the two rows distinct, so this is an insert for each account as intended.
    func upsert(_ conversation: Conversation) throws {
        try dbQueue.write { db in try conversation.save(db) }
    }

    func fetch(id: String, ownerUserId: String) throws -> Conversation? {
        try dbQueue.read { db in
            try Conversation.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: id))
        }
    }

    /// Finds an existing 1:1 conversation between the two users, if any.
    func findDirectConversation(ownerUserId: String, userA: String, userB: String) throws -> Conversation? {
        // With deterministic ids this is a direct primary-key lookup (Bug #14).
        let deterministicId = Conversation.deterministicId(participantIds: [userA, userB])
        if let match = try fetch(id: deterministicId, ownerUserId: ownerUserId) {
            return match
        }
        // Fall back to the old scan so conversations created before the change are
        // still found rather than silently duplicated.
        return try dbQueue.read { db in
            try Conversation
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("isGroup") == false)
                .fetchAll(db)
                .first { Set($0.participantIds) == Set([userA, userB]) }
        }
    }

    /// Orders by actual last activity, as the name always claimed (Bug #15).
    func fetchAllSortedByRecentActivity(ownerUserId: String) throws -> [Conversation] {
        try dbQueue.read { db in
            try Conversation.fetchAll(db, sql: """
                SELECT c.*
                FROM conversations c
                LEFT JOIN (
                    SELECT conversationId, MAX(createdAt) AS lastAt
                    FROM messages
                    WHERE ownerUserId = ?
                    GROUP BY conversationId
                ) m ON m.conversationId = c.id
                WHERE c.ownerUserId = ?
                ORDER BY COALESCE(m.lastAt, c.lastMessageAt, c.createdAt) DESC
                """, arguments: [ownerUserId, ownerUserId])
        }
    }

    /// Keeps the denormalised column in step with the messages table (Bug #15).
    /// Only ever moves forward, so an out-of-order backfill can't drag a conversation
    /// back down the list.
    func touchLastMessageAt(conversationId: String, ownerUserId: String, date: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE conversations
                SET lastMessageAt = ?
                WHERE id = ? AND ownerUserId = ?
                  AND (lastMessageAt IS NULL OR lastMessageAt < ?)
                """, arguments: [date, conversationId, ownerUserId, date])
        }
    }

    func deleteAll(ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try Conversation.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
        }
    }
}
