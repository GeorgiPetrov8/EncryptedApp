import Foundation
import GRDB

/// Every read is scoped to the owning account (Bug #10).
final class ConversationRepository {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    func upsert(_ conversation: Conversation) throws {
        try dbQueue.write { db in try conversation.save(db) }
    }

    func fetch(id: String, ownerUserId: String) throws -> Conversation? {
        try dbQueue.read { db in
            try Conversation
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("id") == id)
                .fetchOne(db)
        }
    }

    /// Finds an existing 1:1 conversation between the two users, if any.
    func findDirectConversation(ownerUserId: String, userA: String, userB: String) throws -> Conversation? {
        // FIX (Bug #14): with deterministic ids this is a direct primary-key lookup,
        // not a full scan with an in-memory set comparison.
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

    /// FIX (Bug #15): orders by actual last activity, as the name always claimed.
    ///
    /// The previous implementation was `order(Column("createdAt").desc)` — the
    /// conversation's *creation* date. A chat that had just received a message stayed
    /// wherever it was, so the list looked frozen.
    ///
    /// `lastMessageAt` is maintained on write, but the aggregate is still computed
    /// here via a LEFT JOIN so that ordering stays correct even if a write path ever
    /// forgets to update the denormalised column.
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

    /// FIX (Bug #15): keeps the denormalised column in step with the messages table.
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
