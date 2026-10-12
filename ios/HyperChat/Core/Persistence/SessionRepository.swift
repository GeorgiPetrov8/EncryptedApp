import Foundation
import GRDB

/// Sessions are scoped to the owning account (Bug #10).
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

    /// FIX (Pack 8, Critical #1): scoped delete, used to roll back a session
    /// whose handshake never reached the peer.
    func delete(ownerUserId: String, otherUserId: String) throws {
        try dbQueue.write { db in
            _ = try SessionRecord
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("otherUserId") == otherUserId)
                .deleteAll(db)
        }
    }

    func deleteAll(ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try SessionRecord.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
        }
    }
}
