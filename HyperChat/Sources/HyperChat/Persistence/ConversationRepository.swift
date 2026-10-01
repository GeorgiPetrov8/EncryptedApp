import Foundation
import GRDB

/// Every read and write is scoped to the owning account (Bug #10).
final class ConversationRepository {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    private static func key(ownerUserId: String, id: String) -> [String: DatabaseValueConvertible] {
        ["ownerUserId": ownerUserId, "id": id]
    }

    /// Safe because the primary key is `(ownerUserId, id)`.
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
        // Fall back to the old scan so conversations created before the change
        // are still found rather than silently duplicated.
        return try dbQueue.read { db in
            try Conversation
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("isGroup") == false)
                .fetchAll(db)
                .first { Set($0.participantIds) == Set([userA, userB]) }
        }
    }

    /// Orders by actual last activity (Bug #15).
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

    func fetchAll(
        ownerUserId: String,
        relationshipState: RelationshipState
    ) throws -> [Conversation] {
        try dbQueue.read { db in
            try Conversation
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("relationshipState") == relationshipState.rawValue)
                .order(Column("inviteSentAt").desc)
                .fetchAll(db)
        }
    }

    /// FIX (invitations): removes one conversation. Its messages, media rows and
    /// shared-pad items go with it via the composite foreign keys' cascade.
    /// Used when the user declines an invitation, so a declined request
    /// doesn't linger in their chat list.
    func delete(id: String, ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try Conversation.deleteOne(db, key: Self.key(ownerUserId: ownerUserId, id: id))
        }
    }

    func deleteAll(ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try Conversation.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
        }
    }
}
