import Foundation
import GRDB
import os

/// Owns the SQLite connection and schema migrations.
///
/// Design note on "encrypted database": the original spec calls for
/// SQLCipher (whole-file encryption). SQLCipher requires linking a custom
/// OpenSSL-backed SQLite build, which is a heavier dependency than fits a
/// scaffold. Instead, this project layers iOS Data Protection on the
/// database files with application-level AES-256-GCM encryption of every
/// sensitive column.
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

        // Protect the directory before the database exists, so files created
        // inside inherit the class — this closes the window where `-wal` and
        // `-shm` are created by SQLite before any client-side attribute
        // could apply (Bug #22).
        try Self.applyFileProtection(to: folder)

        let dbURL = folder.appendingPathComponent(fileName)
        self.databaseURL = dbURL

        var config = Configuration()
        config.foreignKeysEnabled = true
        // SQLite recreates `-wal`/`-shm` after a clean shutdown, so the
        // attribute has to be reapplied whenever the database is opened
        // (Bug #22).
        config.prepareDatabase { _ in
            Self.applyFileProtectionToDatabaseFiles(at: dbURL)
        }

        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)

        Self.applyFileProtectionToDatabaseFiles(at: dbURL)
        try Self.migrator.migrate(dbQueue)

        #if DEBUG
        Self.assertFileProtectionCoversAllDatabaseFiles(at: dbURL)
        try Self.assertExpectedMigrationsApplied(dbQueue)
        #endif
    }

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

    /// Guards against a mistake this project has already made once: a
    /// migration (`v6_media_composite_primary_key`) shipped in its own file
    /// as a `register(in:)` function that a comment asked the reader to
    /// wire up — and nobody did, so the shipped schema silently kept the
    /// exact single-column primary key that migration existed to replace.
    /// Every subsequent migration is now written directly in this file's
    /// `migrator`, in the one place that's actually executed, specifically
    /// so this list and reality can't drift apart again. The list itself is
    /// still worth keeping, as a second, independent check that catches a
    /// typo'd or accidentally-removed `registerMigration` call.
    private static func assertExpectedMigrationsApplied(_ dbQueue: DatabaseQueue) throws {
        let applied = try dbQueue.read { db in try migrator.appliedIdentifiers(db) }
        for expected in expectedMigrationIdentifiers {
            assert(applied.contains(expected), "Migration not applied: \(expected)")
        }
    }

    private static let expectedMigrationIdentifiers = [
        "v1_initial_schema",
        "v2_identity_verification",
        "v3_account_scoping_and_replay_protection",
        "v4_activity_ordering_and_media_ownership",
        "v5_composite_primary_keys",
        "v6_media_composite_primary_key",
        "v7_shared_note_pad",
    ]
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

        /// Activity ordering and media ownership (Bugs #15, #23).
        migrator.registerMigration("v4_activity_ordering_and_media_ownership") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "lastMessageAt", .datetime)
            }
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

            try db.execute(sql: "DELETE FROM media WHERE messageId = '' OR messageId IS NULL")
        }

        /// Composite primary keys for `users`, `conversations` and `messages`.
        migrator.registerMigration("v5_composite_primary_keys", foreignKeyChecks: .deferred) { db in

            // MARK: users

            try db.create(table: "users_new") { t in
                t.column("ownerUserId", .text).notNull()
                t.column("id", .text).notNull()
                t.column("username", .text).notNull()
                t.column("publicKey", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("identitySigningKey", .blob)
                t.column("isVerified", .boolean).notNull().defaults(to: false)
                t.column("identityChangedAt", .datetime)
                t.column("pendingIdentityAgreementKey", .blob)
                t.column("pendingIdentitySigningKey", .blob)
                t.primaryKey(["ownerUserId", "id"])
                t.uniqueKey(["ownerUserId", "username"])
            }

            try db.execute(sql: """
                INSERT OR IGNORE INTO users_new
                    (ownerUserId, id, username, publicKey, createdAt, identitySigningKey,
                     isVerified, identityChangedAt, pendingIdentityAgreementKey, pendingIdentitySigningKey)
                SELECT o.ownerUserId, u.id, u.username, u.publicKey, u.createdAt, u.identitySigningKey,
                       u.isVerified, u.identityChangedAt, u.pendingIdentityAgreementKey, u.pendingIdentitySigningKey
                FROM users u
                CROSS JOIN (
                    SELECT DISTINCT ownerUserId FROM conversations WHERE ownerUserId <> ''
                ) o
                """)
            try db.drop(table: "users")
            try db.rename(table: "users_new", to: "users")
            try db.create(index: "idx_users_owner", on: "users", columns: ["ownerUserId"])

            // MARK: conversations

            try db.create(table: "conversations_new") { t in
                t.column("ownerUserId", .text).notNull()
                t.column("id", .text).notNull()
                t.column("participantIds", .text).notNull()
                t.column("isGroup", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("lastMessageAt", .datetime)
                t.primaryKey(["ownerUserId", "id"])
            }
            try db.execute(sql: """
                INSERT INTO conversations_new (ownerUserId, id, participantIds, isGroup, createdAt, lastMessageAt)
                SELECT ownerUserId, id, participantIds, isGroup, createdAt, lastMessageAt FROM conversations
                """)
            try db.drop(table: "conversations")
            try db.rename(table: "conversations_new", to: "conversations")
            try db.create(
                index: "idx_conversations_owner_activity",
                on: "conversations",
                columns: ["ownerUserId", "lastMessageAt"]
            )

            // MARK: messages

            try db.create(table: "messages_new") { t in
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
            try db.execute(sql: """
                INSERT INTO messages_new
                    (ownerUserId, id, conversationId, senderId, encryptedContent, contentType, deliveryStatus, createdAt)
                SELECT ownerUserId, id, conversationId, senderId, encryptedContent, contentType, deliveryStatus, createdAt
                FROM messages
                """)
            try db.drop(table: "messages")
            try db.rename(table: "messages_new", to: "messages")
            try db.create(
                index: "idx_messages_owner_conversation_created",
                on: "messages",
                columns: ["ownerUserId", "conversationId", "createdAt"]
            )

            // MARK: media — interim rebuild so the composite foreign key can be added.
            // The primary key stays single-column here; corrected in v6.

            try db.create(table: "media_new") { t in
                t.column("id", .text).primaryKey()
                t.column("ownerUserId", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("encryptedFilePath", .text).notNull()
                t.column("encryptedThumbnail", .blob)
                t.column("fileSize", .integer).notNull()
                t.column("mediaType", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.foreignKey(
                    ["ownerUserId", "messageId"],
                    references: "messages",
                    columns: ["ownerUserId", "id"],
                    onDelete: .cascade
                )
            }
            try db.execute(sql: """
                INSERT INTO media_new
                    (id, ownerUserId, messageId, encryptedFilePath, encryptedThumbnail, fileSize, mediaType, createdAt)
                SELECT m.id, m.ownerUserId, m.messageId, m.encryptedFilePath, m.encryptedThumbnail,
                       m.fileSize, m.mediaType, m.createdAt
                FROM media m
                WHERE EXISTS (
                    SELECT 1 FROM messages msg
                    WHERE msg.id = m.messageId AND msg.ownerUserId = m.ownerUserId
                )
                """)
            try db.drop(table: "media")
            try db.rename(table: "media_new", to: "media")
            try db.create(index: "idx_media_owner", on: "media", columns: ["ownerUserId"])
            try db.create(index: "idx_media_message", on: "media", columns: ["ownerUserId", "messageId"])
        }

        /// `media` gets a composite primary key too.
        ///
        /// v5 left `media.id` single-column, reasoned as "a server-assigned
        /// upload id, globally unique — only the parent reference needs an
        /// owner." Global uniqueness of the *identifier* isn't the
        /// question; the question is how many rows reference it, and the
        /// answer is one per account. When Alice sends Bob a photo, both
        /// cache the same blob under the same `mediaId` and both need a row.
        migrator.registerMigration("v6_media_composite_primary_key", foreignKeyChecks: .deferred) { db in
            try db.create(table: "media_v6") { t in
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

            try db.execute(sql: """
                INSERT INTO media_v6
                    (ownerUserId, id, messageId, encryptedFilePath, encryptedThumbnail, fileSize, mediaType, createdAt)
                SELECT ownerUserId, id, messageId, encryptedFilePath, encryptedThumbnail, fileSize, mediaType, createdAt
                FROM media
                """)

            try db.drop(table: "media")
            try db.rename(table: "media_v6", to: "media")

            try db.create(index: "idx_media_owner", on: "media", columns: ["ownerUserId"])
            try db.create(index: "idx_media_owner_message", on: "media", columns: ["ownerUserId", "messageId"])
            try db.create(index: "idx_media_id", on: "media", columns: ["id"])
        }

        /// FIX (shared notepad): the shared note/todo/buy pad's storage.
        ///
        /// Composite-keyed by `(ownerUserId, conversationId, itemId)` from
        /// day one — unlike `messages`/`media`, this table has never
        /// existed with a weaker key that needed correcting later, because
        /// the account-isolation lesson from v5/v6 was already learned
        /// before this table was designed.
        ///
        /// The foreign key to `conversations(ownerUserId, id)` means
        /// deleting a conversation (should that ever become a supported
        /// action) cascades to its notepad automatically, the same way it
        /// already cascades to that conversation's messages.
        migrator.registerMigration("v7_shared_note_pad") { db in
            try db.create(table: "note_pad_items") { t in
                t.column("ownerUserId", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("itemId", .text).notNull()
                t.column("text", .text).notNull()
                t.column("isDone", .boolean).notNull().defaults(to: false)
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .datetime).notNull()
                t.column("updatedBy", .text).notNull()
                t.primaryKey(["ownerUserId", "conversationId", "itemId"])
                t.foreignKey(
                    ["ownerUserId", "conversationId"],
                    references: "conversations",
                    columns: ["ownerUserId", "id"],
                    onDelete: .cascade
                )
            }
            // Powers `NotePadRepository.fetchAll`'s per-conversation load —
            // the only query pattern this table is ever read through.
            try db.create(
                index: "idx_note_pad_owner_conversation",
                on: "note_pad_items",
                columns: ["ownerUserId", "conversationId"]
            )
        }

        return migrator
    }
}
