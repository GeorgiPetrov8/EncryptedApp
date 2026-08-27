import XCTest
import GRDB
@testable import HyperChat

/// Regression tests for the pack 6 corrections: the unregistered v6 migration and the
/// missing receive-side `MediaItem`.
final class MediaOwnershipTests: XCTestCase {

    // MARK: - The migration is actually applied

    /// The v6 migration existed as a standalone `register(in:)` that nothing called,
    /// so the shipped schema kept the single-column primary key it was written to
    /// replace. This asserts on the real `DatabaseManager` rather than a hand-built
    /// test schema, which is the only way to catch that class of mistake.
    func testAllMigrationsAreRegistered() throws {
        let manager = try DatabaseManager(fileName: "migration-check-\(UUID().uuidString).sqlite")
        defer { Self.removeDatabase(named: manager) }

        let applied = try manager.dbQueue.read { db -> Set<String> in
            let rows = try Row.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            return Set(rows.compactMap { $0["identifier"] as String? })
        }

        for expected in [
            "v1_initial_schema",
            "v2_identity_verification",
            "v3_account_scoping_and_replay_protection",
            "v4_activity_ordering_and_media_ownership",
            "v5_composite_primary_keys",
            "v6_media_composite_primary_key"
        ] {
            XCTAssertTrue(applied.contains(expected), "Migration missing: \(expected)")
        }
    }

    /// The property that matters, asserted directly against the shipped schema: two
    /// accounts must be able to hold a row for the same blob.
    func testShippedSchemaAllowsTwoOwnersOfOneMediaId() throws {
        let manager = try DatabaseManager(fileName: "media-pk-check-\(UUID().uuidString).sqlite")
        defer { Self.removeDatabase(named: manager) }

        let repository = MediaRepository(dbQueue: manager.dbQueue)
        try Self.seedMessage(manager.dbQueue, id: "envelope-1", owners: ["alice", "bob"])

        try repository.insert(Self.makeMedia(id: "shared-blob", messageId: "envelope-1", owner: "alice"))
        // Under the pre-v6 schema this second insert raised a primary-key violation.
        XCTAssertNoThrow(
            try repository.insert(Self.makeMedia(id: "shared-blob", messageId: "envelope-1", owner: "bob"))
        )

        XCTAssertEqual(try repository.fetchAll(ownerUserId: "alice").count, 1)
        XCTAssertEqual(try repository.fetchAll(ownerUserId: "bob").count, 1)
    }

    // MARK: - The recipient owns their copy

    /// `insertIfNotProcessed` had no media parameter, so a received photo produced a
    /// message row and nothing else.
    func testReceivedMediaMessageCreatesAMediaRow() throws {
        let queue = try Self.makeDatabase()
        let messages = MessageRepository(dbQueue: queue)
        let media = MediaRepository(dbQueue: queue)
        try Self.seedConversation(queue, owners: ["bob"])

        let message = Self.makeMessage(id: "envelope-1", owner: "bob", contentType: .image)
        let item = Self.makeMedia(id: "blob-1", messageId: "", owner: "")

        let inserted = try messages.insertIfNotProcessed(
            message,
            media: item,
            envelopeId: "envelope-1",
            recipientUserId: "bob",
            senderId: "alice"
        )

        XCTAssertTrue(inserted)
        let stored = try XCTUnwrap(media.fetch(messageId: "envelope-1", ownerUserId: "bob"))
        XCTAssertEqual(stored.id, "blob-1")
        XCTAssertEqual(stored.ownerUserId, "bob", "the repository must bind the row to the receiving account")
        XCTAssertEqual(stored.messageId, "envelope-1")
    }

    /// The consequence that made this worth fixing: with both sides owning a row, the
    /// sender's cleanup can no longer unlink the file the recipient is still using.
    func testSendersCleanupSparesABlobTheRecipientStillReferences() throws {
        let queue = try Self.makeDatabase()
        let media = MediaRepository(dbQueue: queue)
        try Self.seedConversation(queue, owners: ["alice", "bob"])
        try Self.seedMessage(queue, id: "envelope-1", owners: ["alice", "bob"])

        // Same blob, same on-disk path — the cache is shared and named by mediaId.
        try media.insert(Self.makeMedia(
            id: "shared-blob", messageId: "envelope-1", owner: "alice", path: "/tmp/shared.bin"
        ))
        try media.insert(Self.makeMedia(
            id: "shared-blob", messageId: "envelope-1", owner: "bob", path: "/tmp/shared.bin"
        ))

        let evictable = try media.exclusivelyOwnedPaths(ownerUserId: "alice")
        XCTAssertTrue(evictable.isEmpty, "the recipient's row must keep the shared file alive")
        XCTAssertTrue(try media.isReferencedByOtherOwner(mediaId: "shared-blob", excluding: "alice"))
    }

    /// Without the recipient's row — the old behaviour — the file would be evicted.
    /// This pins the failure mode so a regression is visible rather than silent.
    func testWithoutRecipientRowTheSharedBlobLooksEvictable() throws {
        let queue = try Self.makeDatabase()
        let media = MediaRepository(dbQueue: queue)
        try Self.seedConversation(queue, owners: ["alice"])
        try Self.seedMessage(queue, id: "envelope-1", owners: ["alice"])

        try media.insert(Self.makeMedia(
            id: "shared-blob", messageId: "envelope-1", owner: "alice", path: "/tmp/shared.bin"
        ))

        XCTAssertEqual(
            try media.exclusivelyOwnedPaths(ownerUserId: "alice"),
            ["/tmp/shared.bin"],
            "this is what the recipient's missing row used to cause"
        )
    }

    /// A text message must not produce a media row.
    func testTextMessageCreatesNoMediaRow() throws {
        let queue = try Self.makeDatabase()
        let messages = MessageRepository(dbQueue: queue)
        let media = MediaRepository(dbQueue: queue)
        try Self.seedConversation(queue, owners: ["bob"])

        _ = try messages.insertIfNotProcessed(
            Self.makeMessage(id: "envelope-1", owner: "bob", contentType: .text),
            envelopeId: "envelope-1",
            recipientUserId: "bob",
            senderId: "alice"
        )

        XCTAssertNil(try media.fetch(messageId: "envelope-1", ownerUserId: "bob"))
    }

    /// A replayed envelope must not insert a second media row either.
    func testDuplicateEnvelopeDoesNotDuplicateMedia() throws {
        let queue = try Self.makeDatabase()
        let messages = MessageRepository(dbQueue: queue)
        let media = MediaRepository(dbQueue: queue)
        try Self.seedConversation(queue, owners: ["bob"])

        let message = Self.makeMessage(id: "envelope-1", owner: "bob", contentType: .image)

        XCTAssertTrue(try messages.insertIfNotProcessed(
            message, media: Self.makeMedia(id: "blob-1", messageId: "", owner: ""),
            envelopeId: "envelope-1", recipientUserId: "bob", senderId: "alice"
        ))
        XCTAssertFalse(try messages.insertIfNotProcessed(
            message, media: Self.makeMedia(id: "blob-1", messageId: "", owner: ""),
            envelopeId: "envelope-1", recipientUserId: "bob", senderId: "alice"
        ))

        XCTAssertEqual(try media.fetchAll(ownerUserId: "bob").count, 1)
    }

    // MARK: - Provisional file size is backfilled

    func testFileSizeIsUpdatedAfterDownload() throws {
        let queue = try Self.makeDatabase()
        let media = MediaRepository(dbQueue: queue)
        try Self.seedConversation(queue, owners: ["bob"])
        try Self.seedMessage(queue, id: "envelope-1", owners: ["bob"])

        // Received rows start at 0 — the blob isn't downloaded yet.
        try media.insert(Self.makeMedia(id: "blob-1", messageId: "envelope-1", owner: "bob", fileSize: 0))
        XCTAssertEqual(try media.fetch(id: "blob-1", ownerUserId: "bob")?.fileSize, 0)

        try media.updateFileSize(mediaId: "blob-1", ownerUserId: "bob", fileSize: 4096)
        XCTAssertEqual(try media.fetch(id: "blob-1", ownerUserId: "bob")?.fileSize, 4096)
    }

    func testFileSizeUpdateIsScopedByOwner() throws {
        let queue = try Self.makeDatabase()
        let media = MediaRepository(dbQueue: queue)
        try Self.seedConversation(queue, owners: ["alice", "bob"])
        try Self.seedMessage(queue, id: "envelope-1", owners: ["alice", "bob"])

        try media.insert(Self.makeMedia(id: "shared", messageId: "envelope-1", owner: "alice", fileSize: 100))
        try media.insert(Self.makeMedia(id: "shared", messageId: "envelope-1", owner: "bob", fileSize: 0))

        try media.updateFileSize(mediaId: "shared", ownerUserId: "bob", fileSize: 4096)

        XCTAssertEqual(try media.fetch(id: "shared", ownerUserId: "alice")?.fileSize, 100)
        XCTAssertEqual(try media.fetch(id: "shared", ownerUserId: "bob")?.fileSize, 4096)
    }

    // MARK: - Payload decoding

    /// `MediaKeyPayload` had to become visible outside `MediaEncryptionService` for
    /// the receive-side fix to be written at all.
    func testMediaKeyPayloadRoundTrips() throws {
        let payload = MediaKeyPayload(
            mediaId: "blob-1",
            key: Data(repeating: 0x01, count: 32),
            thumbnailKey: Data(repeating: 0x02, count: 32)
        )
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MediaKeyPayload.self, from: encoded)

        XCTAssertEqual(decoded.mediaId, "blob-1")
        XCTAssertEqual(decoded.key, payload.key)
        XCTAssertEqual(decoded.thumbnailKey, payload.thumbnailKey)
    }

    // MARK: - Helpers

    private static func removeDatabase(named manager: DatabaseManager) {
        // Best-effort cleanup of the temporary database and its WAL/SHM siblings.
        guard let folder = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in contents where name.hasPrefix("migration-check-") || name.hasPrefix("media-pk-check-") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func makeMedia(
        id: String,
        messageId: String,
        owner: String,
        path: String = "/tmp/blob.bin",
        fileSize: Int = 128
    ) -> MediaItem {
        MediaItem(
            id: id,
            messageId: messageId,
            ownerUserId: owner,
            encryptedFilePath: path,
            encryptedThumbnail: nil,
            fileSize: fileSize,
            mediaType: .image,
            createdAt: Date()
        )
    }

    private static func makeMessage(
        id: String,
        owner: String,
        contentType: MessageContentType
    ) -> Message {
        Message(
            id: id,
            ownerUserId: owner,
            conversationId: "conv-1",
            senderId: "alice",
            encryptedContent: Data([0xAA]),
            contentType: contentType,
            deliveryStatus: .delivered,
            createdAt: Date()
        )
    }

    private static func seedConversation(_ queue: DatabaseQueue, owners: [String]) throws {
        try queue.write { db in
            for owner in owners {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO conversations (ownerUserId, id, participantIds, isGroup, createdAt)
                    VALUES (?, 'conv-1', '["alice","bob"]', 0, ?)
                    """, arguments: [owner, Date()])
            }
        }
    }

    private static func seedMessage(_ queue: DatabaseQueue, id: String, owners: [String]) throws {
        try seedConversation(queue, owners: owners)
        try queue.write { db in
            for owner in owners {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO messages
                        (ownerUserId, id, conversationId, senderId, encryptedContent, contentType, deliveryStatus, createdAt)
                    VALUES (?, ?, 'conv-1', 'alice', x'AA', 'image', 'delivered', ?)
                    """, arguments: [owner, id, Date()])
            }
        }
    }

    /// In-memory schema matching migration v6.
    private static func makeDatabase() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        try queue.write { db in
            try db.create(table: "conversations") { t in
                t.column("ownerUserId", .text).notNull()
                t.column("id", .text).notNull()
                t.column("participantIds", .text).notNull()
                t.column("isGroup", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("lastMessageAt", .datetime)
                t.primaryKey(["ownerUserId", "id"])
            }
            try db.create(table: "messages") { t in
                t.column("ownerUserId", .text).notNull()
                t.column("id", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("senderId", .text).notNull()
                t.column("encryptedContent", .blob).notNull()
                t.column("contentType", .text).notNull()
                t.column("deliveryStatus", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["ownerUserId", "id"])
                t.foreignKey(
                    ["ownerUserId", "conversationId"],
                    references: "conversations",
                    columns: ["ownerUserId", "id"],
                    onDelete: .cascade
                )
            }
            try db.create(table: "media") { t in
                t.column("ownerUserId", .text).notNull()
                t.column("id", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("encryptedFilePath", .text).notNull()
                t.column("encryptedThumbnail", .blob)
                t.column("fileSize", .integer).notNull()
                t.column("mediaType", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["ownerUserId", "id"])
                t.foreignKey(
                    ["ownerUserId", "messageId"],
                    references: "messages",
                    columns: ["ownerUserId", "id"],
                    onDelete: .cascade
                )
            }
            try db.create(table: "processed_envelopes") { t in
                t.column("recipientUserId", .text).notNull()
                t.column("senderId", .text).notNull()
                t.column("envelopeId", .text).notNull()
                t.column("receivedAt", .datetime).notNull()
                t.primaryKey(["recipientUserId", "senderId", "envelopeId"])
            }
        }
        return queue
    }
}
