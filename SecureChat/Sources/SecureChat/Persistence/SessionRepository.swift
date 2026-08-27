import Foundation
import GRDB

/// FIX (Bug #10): sessions are scoped to the owning account.
///
/// The v1 schema made `otherUserId` globally unique, so two accounts on the same
/// device talking to the same peer overwrote each other's ratchet state — and each
/// would then fail to decrypt the other's, because the storage keys differ per
/// account. Uniqueness is now `(ownerUserId, otherUserId)`.
final class SessionRepository {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    func upsert(ownerUserId: String, otherUserId: String, encryptedState: Data) throws {
        try dbQueue.write { db in
            if var existing = try SessionRecord
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("otherUserId") == otherUserId)
                .fetchOne(db) {
                existing.encryptedState = encryptedState
                existing.updatedAt = Date()
                try existing.update(db)
            } else {
                let record = SessionRecord(
                    id: UUID().uuidString,
                    ownerUserId: ownerUserId,
                    otherUserId: otherUserId,
                    encryptedState: encryptedState,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                try record.insert(db)
            }
        }
    }

    func fetch(ownerUserId: String, otherUserId: String) throws -> SessionRecord? {
        try dbQueue.read { db in
            try SessionRecord
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("otherUserId") == otherUserId)
                .fetchOne(db)
        }
    }

    /// FIX (Bug #10): used by `deleteAccount`.
    func deleteAll(ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try SessionRecord.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
        }
    }
}
