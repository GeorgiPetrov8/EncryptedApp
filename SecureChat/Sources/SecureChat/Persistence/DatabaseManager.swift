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

        // Protect the directory before the database exists, so files created inside
        // inherit the class — this closes the window where `-wal` and `-shm` are
        // created by SQLite before any client-side attribute could apply (Bug #22).
        try Self.applyFileProtection(to: folder)

        let dbURL = folder.appendingPathComponent(fileName)
        self.databaseURL = dbURL

        var config = Configuration()
        config.foreignKeysEnabled = true
        // SQLite recreates `-wal`/`-shm` after a clean shutdown, so the attribute has
        // to be reapplied whenever the database is opened (Bug #22).
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

    /// FIX: guards against the exact mistake this file just corrected.
    ///
    /// Migration v6 lived in its own file as `MediaCompositeKeyMigration.register(in:)`
    /// with a comment instructing the reader to wire it up — and nobody did, so the
    /// `media` table silently kept the single-column primary key that v6 exists to
    /// replace. Every `MediaRepository` method written against the composite key was
    /// operating on a schema that couldn't support it.
    ///
    /// A migration that has to be remembered is a migration that gets forgotten. This
    /// assert makes an unregistered migration fail loudly in development instead of
    /// only surfacing as a constraint violation the first time two accounts cache the
    /// same blob.
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
        "v6_media_composite_primary_key"
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
        ///
        /// v3 added `ownerUserId` as a *column* and filtered every read by it, but left
        /// the primary keys as `id` alone. That was survivable only while ids were
        /// random UUIDs. Bug #14's deterministic conversation id removed the luck, and
        /// `Message.id` comes from the sender's `localMessageId`, so two accounts on
        /// the same device collide on every exchanged message.
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

            // Pre-v5 `users` rows carry no owner, so there is no way to know which
            // account pinned them. Copying each row into every known account's
            // namespace preserves display names and pinned keys for all existing
            // accounts; dropping them would silently reset every trust decision.
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
                // The foreign key must be composite too, otherwise a message could
                // reference a conversation belonging to a different account.
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
            //
            // The primary key stays single-column here and is corrected in v6; see the
            // note there for why the original reasoning was wrong.

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

        /// FIX: v6 is now registered here, in the migrator, rather than sitting in a
        /// separate file behind a comment telling the reader to wire it up.
        ///
        /// It wasn't wired up. `MediaCompositeKeyMigration.register(in:)` was never
        /// called from anywhere, so the `media` table kept the single-column primary
        /// key while `MediaRepository.isReferencedByOtherOwner` and
        /// `exclusivelyOwnedPaths` were written assuming the composite one — queries
        /// against a schema that could not support them. The second account to cache a
        /// blob would have hit a primary-key violation.
        ///
        /// On the substance: v5 justified leaving `media.id` alone as "a server-assigned
        /// upload id, globally unique — only the parent reference needs an owner". The
        /// premise is true and the conclusion doesn't follow. Global uniqueness of the
        /// *identifier* isn't the question; the question is how many rows reference it,
        /// and the answer is one per account. When Alice sends Bob a photo, both cache
        /// the same blob under the same `mediaId` and both need a row.
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
            // Supports `isReferencedByOtherOwner` and `exclusivelyOwnedPaths`, both of
            // which look a blob up across owners.
            try db.create(index: "idx_media_id", on: "media", columns: ["id"])
        }

        return migrator
    }
}
