import Foundation
import GRDB

/// FIX (Bug #10): every read is now scoped to the owning account.
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
        try dbQueue.read { db in
            try Conversation
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("isGroup") == false)
                .fetchAll(db)
                .first { Set($0.participantIds) == Set([userA, userB]) }
        }
    }

    /// Without the owner filter, a second account registered on the same device
    /// listed the first account's conversations — rows it could not decrypt, since
    /// storage keys are now per-account.
    func fetchAllSortedByRecentActivity(ownerUserId: String) throws -> [Conversation] {
        try dbQueue.read { db in
            try Conversation
                .filter(Column("ownerUserId") == ownerUserId)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// FIX (Bug #10): used by `deleteAccount`.
    func deleteAll(ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try Conversation.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
        }
    }
}
