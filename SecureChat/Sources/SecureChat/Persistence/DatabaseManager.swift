import Foundation
import GRDB
import os

/// Owns the SQLite connection and schema migrations.
///
/// Design note on "encrypted database": the original spec calls for SQLCipher
/// (whole-file encryption). SQLCipher requires linking a custom OpenSSL-backed
/// SQLite build, which is a heavier dependency than fits a scaffold. Instead, this
/// project layers iOS Data Protection on the database files with application-level
/// AES-256-GCM encryption of every sensitive column.
final class DatabaseManager {
    let dbQueue: DatabaseQueue
    private let databaseURL: URL
    private static let logger = Logger(subsystem: "com.securechat", category: "database")

    init(fileName: String = "securechat.sqlite") throws {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        // FIX (Bug #22), part 1: protect the *directory* before the database exists.
        //
        // Files created inside inherit the directory's protection class, which closes
        // the window where `-wal` and `-shm` are created by SQLite before any
        // client-side attribute could be applied to them.
        try Self.applyFileProtection(to: folder)

        let dbURL = folder.appendingPathComponent(fileName)
        self.databaseURL = dbURL

        var config = Configuration()
        // FIX (Bug #22), part 2: re-assert protection on every open.
        //
        // SQLite recreates `-wal`/`-shm` after a clean shutdown, so applying the
        // attribute once at creation time is not enough — it has to be reapplied
        // whenever the database is opened.
        config.prepareDatabase { _ in
            Self.applyFileProtectionToDatabaseFiles(at: dbURL)
        }

        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)

        Self.applyFileProtectionToDatabaseFiles(at: dbURL)
        try Self.migrator.migrate(dbQueue)

        #if DEBUG
        Self.assertFileProtectionCoversAllDatabaseFiles(at: dbURL)
        #endif
    }

    /// FIX (Bug #22): the original only protected the main `.sqlite` file.
    ///
    /// GRDB uses WAL journalling by default, so the most recent transactions live in
    /// `securechat.sqlite-wal` — which had no protection class at all and was
    /// therefore readable before first unlock. That is precisely the threat model the
    /// comment at the top of this file claims to cover.
    private static var databaseFileURLs: (URL) -> [URL] = { dbURL in
        [
            dbURL,
            URL(fileURLWithPath: dbURL.path + "-wal"),
            URL(fileURLWithPath: dbURL.path + "-shm")
        ]
    }

    private static func applyFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func applyFileProtectionToDatabaseFiles(at dbURL: URL) {
        for url in databaseFileURLs(dbURL) where FileManager.default.fileExists(atPath: url.path) {
            do {
                try applyFileProtection(to: url)
            } catch {
                logger.error("Couldn't apply file protection to \(url.lastPathComponent, privacy: .public)")
            }
        }
    }

    #if DEBUG
    /// Fails loudly in development if any database file is unprotected, so a future
    /// change to journalling mode or file naming can't silently reopen this hole.
    private static func assertFileProtectionCoversAllDatabaseFiles(at dbURL: URL) {
        for url in databaseFileURLs(dbURL) where FileManager.default.fileExists(atPath: url.path) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let protection = attributes?[.protectionKey] as? FileProtectionType
            assert(
                protection == .completeUntilFirstUserAuthentication,
                "Unprotected database file: \(url.lastPathComponent)"
            )
        }
    }
    #endif

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "users") { t in
                t.column("id", .text).primaryKey()
                t.column("username", .text).notNull().unique()
                t.column("publicKey", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("participantIds", .text).notNull()
                t.column("isGroup", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text).notNull().indexed()
                    .references("conversations", column: "id", onDelete: .cascade)
                t.column("senderId", .text).notNull()
                t.column("encryptedContent", .blob).notNull()
                t.column("contentType", .text).notNull()
                t.column("deliveryStatus", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "media") { t in
                t.column("id", .text).primaryKey()
                t.column("messageId", .text).notNull().indexed()
                    .references("messages", column: "id", onDelete: .cascade)
                t.column("encryptedFilePath", .text).notNull()
                t.column("encryptedThumbnail", .blob)
                t.column("fileSize", .integer).notNull()
                t.column("mediaType", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("otherUserId", .text).notNull().unique()
                t.column("encryptedState", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        /// Identity pinning / verification columns (Bug #2).
        migrator.registerMigration("v2_identity_verification") { db in
            try db.alter(table: "users") { t in
                t.add(column: "identitySigningKey", .blob)
                t.add(column: "isVerified", .boolean).notNull().defaults(to: false)
                t.add(column: "identityChangedAt", .datetime)
                t.add(column: "pendingIdentityAgreementKey", .blob)
                t.add(column: "pendingIdentitySigningKey", .blob)
            }
        }

        /// Replay protection and per-account data scoping (Bugs #8, #10).
        migrator.registerMigration("v3_account_scoping_and_replay_protection") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "ownerUserId", .text).notNull().defaults(to: "")
            }
            try db.create(index: "idx_conversations_owner", on: "conversations", columns: ["ownerUserId"])

            try db.alter(table: "messages") { t in
                t.add(column: "ownerUserId", .text).notNull().defaults(to: "")
            }
            // FIX (Bug #15): this index is what keeps the MAX(createdAt) aggregate
            // in `fetchAllSortedByRecentActivity` cheap.
            try db.create(
                index: "idx_messages_owner_conversation_created",
                on: "messages",
                columns: ["ownerUserId", "conversationId", "createdAt"]
            )

            try db.create(table: "sessions_new") { t in
                t.column("id", .text).primaryKey()
                t.column("ownerUserId", .text).notNull()
                t.column("otherUserId", .text).notNull()
                t.column("encryptedState", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["ownerUserId", "otherUserId"])
            }
            try db.execute(sql: """
                INSERT INTO sessions_new (id, ownerUserId, otherUserId, encryptedState, createdAt, updatedAt)
                SELECT id, '', otherUserId, encryptedState, createdAt, updatedAt FROM sessions
                """)
            try db.drop(table: "sessions")
            try db.rename(table: "sessions_new", to: "sessions")

            try db.create(table: "processed_envelopes") { t in
                t.column("recipientUserId", .text).notNull()
                t.column("senderId", .text).notNull()
                t.column("envelopeId", .text).notNull()
                t.column("receivedAt", .datetime).notNull()
                t.primaryKey(["recipientUserId", "senderId", "envelopeId"])
            }
            try db.create(index: "idx_processed_envelopes_receivedAt", on: "processed_envelopes", columns: ["receivedAt"])
        }

        /// FIX (Bug #15) + FIX (Bug #23): activity ordering and media ownership.
        migrator.registerMigration("v4_activity_ordering_and_media_ownership") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "lastMessageAt", .datetime)
            }
            // Seed from existing history so ordering is correct immediately after
            // upgrade rather than only after the next message arrives.
            try db.execute(sql: """
                UPDATE conversations
                SET lastMessageAt = (
                    SELECT MAX(createdAt) FROM messages WHERE messages.conversationId = conversations.id
                )
                """)
            try db.create(
                index: "idx_conversations_owner_activity",
                on: "conversations",
                columns: ["ownerUserId", "lastMessageAt"]
            )

            try db.alter(table: "media") { t in
                t.add(column: "ownerUserId", .text).notNull().defaults(to: "")
            }
            try db.create(index: "idx_media_owner", on: "media", columns: ["ownerUserId"])

            // FIX (Bug #13): remove pre-existing orphans.
            //
            // Every media row written before this fix carried `messageId = ""`, so it
            // referenced no message and could never be found by `fetch(messageId:)`.
            try db.execute(sql: "DELETE FROM media WHERE messageId = '' OR messageId IS NULL")
        }

        return migrator
    }
}
