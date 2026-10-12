import Foundation
import GRDB

/// Every `messageId` lookup is scoped by `ownerUserId`.
///
/// The composite primary key made `Message.id` legitimately shared: Alice's copy and
/// Bob's copy of the same envelope are two rows with the same id and different owners.
/// That is what makes an unscoped `WHERE messageId = ?` wrong here.
final class MediaRepository {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    private static func key(ownerUserId: String, id: String) -> [String: DatabaseValueConvertible] {
        ["ownerUserId": ownerUserId, "id": id]
    }

    func insert(_ item: MediaItem) throws {
        try dbQueue.write { db in try item.insert(db) }
    }

    func fetch(messageId: String, ownerUserId: String) throws -> MediaItem? {
        try dbQueue.read { db in
            try MediaItem
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("messageId") == messageId)
                .fetchOne(db)
        }
    }

    /// FIX: requires an owner.
    ///
    /// This took `id` alone, which was only defensible while `media` had a
    /// single-column primary key. Migration v6 makes `(ownerUserId, id)` the key
    /// precisely so two accounts can reference the same blob, at which point a lookup
    /// by id alone is ambiguous.
    func fetch(id: String, ownerUserId: String) throws -> MediaItem? {
        try dbQueue.read { db in
            try MediaItem.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: id))
        }
    }

    func fetchAll(ownerUserId: String) throws -> [MediaItem] {
        try dbQueue.read { db in
            try MediaItem.filter(Column("ownerUserId") == ownerUserId).fetchAll(db)
        }
    }

    /// FIX: backfills the size recorded as 0 by `makeReceivedMediaItem`.
    ///
    /// A received media row is created before the blob is downloaded, so its size
    /// isn't known yet. `decryptMedia` calls this once the bytes are in hand.
    func updateFileSize(mediaId: String, ownerUserId: String, fileSize: Int) throws {
        try dbQueue.write { db in
            guard var item = try MediaItem.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: mediaId)),
                  item.fileSize != fileSize else { return }
            item.fileSize = fileSize
            try item.update(db)
        }
    }

    /// Deleting a media row must also remove the file it points at (Bug #23) — the
    /// schema's cascade only removes the row.
    ///
    /// Returns the referenced paths so the caller can unlink them after the
    /// transaction commits; deleting files inside a write block would leave the disk
    /// and the database inconsistent if the transaction rolled back.
    @discardableResult
    func deleteAll(ownerUserId: String) throws -> [String] {
        try dbQueue.write { db in
            let items = try MediaItem.filter(Column("ownerUserId") == ownerUserId).fetchAll(db)
            _ = try MediaItem.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
            return items.map(\.encryptedFilePath)
        }
    }

    /// Scoped delete. Unscoped, this unlinked the file backing the other account's
    /// copy of the same message.
    @discardableResult
    func delete(messageId: String, ownerUserId: String) throws -> [String] {
        try dbQueue.write { db in
            let items = try MediaItem
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("messageId") == messageId)
                .fetchAll(db)
            _ = try MediaItem
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("messageId") == messageId)
                .deleteAll(db)
            return items.map(\.encryptedFilePath)
        }
    }

    /// A file may be referenced by more than one account's row — `mediaId` is
    /// server-assigned and both parties to a conversation cache the same blob. Before
    /// unlinking on behalf of one account, the caller must know whether anyone else
    /// still needs it.
    ///
    /// This only reports the truth if both sides actually create rows; the receive
    /// path that was missing is what made it answer "nobody else" when the recipient
    /// did in fact hold a cached copy.
    func isReferencedByOtherOwner(mediaId: String, excluding ownerUserId: String) throws -> Bool {
        try dbQueue.read { db in
            try MediaItem
                .filter(Column("id") == mediaId)
                .filter(Column("ownerUserId") != ownerUserId)
                .fetchCount(db) > 0
        }
    }

    /// Paths owned by `ownerUserId` that no other account references.
    /// Safe to unlink; anything excluded is still in use elsewhere on this device.
    func exclusivelyOwnedPaths(ownerUserId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.encryptedFilePath
                FROM media m
                WHERE m.ownerUserId = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM media other
                      WHERE other.id = m.id AND other.ownerUserId <> ?
                  )
                """, arguments: [ownerUserId, ownerUserId])
        }
    }
}
