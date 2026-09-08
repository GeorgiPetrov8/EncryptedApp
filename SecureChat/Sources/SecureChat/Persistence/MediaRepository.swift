import Foundation
import GRDB

final class MediaRepository {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    func insert(_ item: MediaItem) throws {
        try dbQueue.write { db in try item.insert(db) }
    }

    func fetch(messageId: String) throws -> MediaItem? {
        try dbQueue.read { db in
            try MediaItem.filter(Column("messageId") == messageId).fetchOne(db)
        }
    }

    func fetch(id: String) throws -> MediaItem? {
        try dbQueue.read { db in try MediaItem.fetchOne(db, key: id) }
    }

    func fetchAll(ownerUserId: String) throws -> [MediaItem] {
        try dbQueue.read { db in
            try MediaItem.filter(Column("ownerUserId") == ownerUserId).fetchAll(db)
        }
    }

    /// FIX (Bug #23): deleting a media row must also remove the file it points at.
    ///
    /// The schema's `onDelete: .cascade` only removes the database row. The encrypted
    /// blob on disk was left behind forever — so "delete this message" removed the
    /// index but not the data.
    ///
    /// Returns the paths that were referenced, so the caller can unlink them after
    /// the transaction commits (deleting files inside a write block would leave the
    /// disk and the database inconsistent if the transaction rolled back).
    @discardableResult
    func deleteAll(ownerUserId: String) throws -> [String] {
        try dbQueue.write { db in
            let items = try MediaItem.filter(Column("ownerUserId") == ownerUserId).fetchAll(db)
            _ = try MediaItem.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
            return items.map(\.encryptedFilePath)
        }
    }

    @discardableResult
    func delete(messageId: String) throws -> [String] {
        try dbQueue.write { db in
            let items = try MediaItem.filter(Column("messageId") == messageId).fetchAll(db)
            _ = try MediaItem.filter(Column("messageId") == messageId).deleteAll(db)
            return items.map(\.encryptedFilePath)
        }
    }
}
