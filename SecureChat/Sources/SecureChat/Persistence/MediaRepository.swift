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
}
