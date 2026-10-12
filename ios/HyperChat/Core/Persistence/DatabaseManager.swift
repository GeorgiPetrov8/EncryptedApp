import Foundation
import GRDB
import os

/// Owns the SQLite connection and schema migrations.
///
/// iOS Data Protection on the database files, plus application-level
/// AES-256-GCM encryption of every sensitive column.
final class DatabaseManager {
    let dbQueue: DatabaseQueue
    private let databaseURL: URL
    private static let logger = Logger(subsystem: "com.HyperChat", category: "database")

    init(fileName: String = "HyperChat.sqlite") throws {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try Self.applyFileProtection(to: folder)

        let dbURL = folder.appendingPathComponent(fileName)
        self.databaseURL = dbURL

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { _ in
            Self.applyFileProtectionToDatabaseFiles(at: dbURL)
        }

        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)

        Self.applyFileProtectionToDatabaseFiles(at: dbURL)
        try Self.migrator.migrate(dbQueue)
        Self.applyFileProtectionToDatabaseFiles(at: dbURL)

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
        let fileManager = FileManager.default
        for url in databaseFileURLs(dbURL) where fileManager.fileExists(atPath: url.path) {
            do {
                try applyFileProtection(to: url)
            } catch {
                logger.error("Couldn't apply file protection to \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    #if DEBUG
    private static func assertFileProtectionCoversAllDatabaseFiles(at dbURL: URL) {
        #if targetEnvironment(simulator)
        logger.debug("Skipping file-protection assertion in Simulator")
        return
        #else
        for url in databaseFileURLs(dbURL) where FileManager.default.fileExists(atPath: url.path) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let attribute = attributes[.protectionKey]
                let protection: FileProtectionType?
                if let value = attribute as? FileProtectionType {
                    protection = value
                } else if let rawValue = attribute as? String {
                    protection = FileProtectionType(rawValue: rawValue)
                } else {
                    protection = nil
                }
                assert(
                    protection == .completeUntilFirstUserAuthentication,
                    "Unprotected database file: \(url.lastPathComponent); protection: \(String(describing: attribute))"
                )
            } catch {
                assertionFailure("Could not inspect file protection for \(url.lastPathComponent): \(error)")
            }
        }
        #endif
    }

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
        "v8_alarms",
        "v9_receipts_presence_invites",
        "v10_message_edits",
        "v11_message_reactions",
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

        migrator.registerMigration("v2_identity_verification") { db in
            try db.alter(table: "users") { t in
                t.add(column: "identitySigningKey", .blob)
                t.add(column: "isVerified", .boolean).notNull().defaults(to: false)
                t.add(column: "identityChangedAt", .datetime)
                t.add(column: "pendingIdentityAgreementKey", .blob)
                t.add(column: "pendingIdentitySigningKey", .blob)
            }
        }

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

        migrator.registerMigration("v5_composite_primary_keys", foreignKeyChecks: .deferred) { db in
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
            try db.create(
                index: "idx_note_pad_owner_conversation",
                on: "note_pad_items",
                columns: ["ownerUserId", "conversationId"]
            )
        }

        migrator.registerMigration("v8_alarms") { db in
            try db.create(table: "alarms") { t in
                t.column("ownerUserId", .text).notNull()
                t.column("id", .text).notNull()
                t.column("hour", .integer).notNull()
                t.column("minute", .integer).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("label", .text).notNull().defaults(to: "Alarm")
                t.column("repeatWeekdays", .text).notNull().defaults(to: "[]")
                t.column("dismissalMode", .text).notNull().defaults(to: "tasks")
                t.column("accountabilityPeerId", .text)
                t.column("requiredTaskCount", .integer).notNull().defaults(to: 3)
                t.column("lastFiredAt", .datetime)
                t.column("lastDismissedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["ownerUserId", "id"])
            }
            try db.create(
                index: "idx_alarms_owner_enabled",
                on: "alarms",
                columns: ["ownerUserId", "isEnabled"]
            )
        }

        migrator.registerMigration("v9_receipts_presence_invites") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "deliveredAt", .datetime)
                t.add(column: "readAt", .datetime)
            }
            try db.alter(table: "users") { t in
                t.add(column: "displayName", .text)
                t.add(column: "avatarFileName", .text)
                t.add(column: "profileUpdatedAt", .datetime)
            }
            try db.alter(table: "conversations") { t in
                t.add(column: "relationshipState", .text).notNull().defaults(to: "accepted")
                t.add(column: "inviteNote", .text)
                t.add(column: "inviteSentAt", .datetime)
                t.add(column: "inviteRespondedAt", .datetime)
            }
            try db.create(
                index: "idx_conversations_owner_state",
                on: "conversations",
                columns: ["ownerUserId", "relationshipState"]
            )
        }

        migrator.registerMigration("v10_message_edits") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "editedAt", .datetime)
            }
        }

        /// NEW: emoji reactions. One row per (message, person); removing a
        /// reaction keeps a tombstone (empty emoji). Deleting a message — or
        /// the whole account — removes its reactions via the cascade.
        migrator.registerMigration("v11_message_reactions") { db in
            try db.create(table: "message_reactions") { t in
                t.column("ownerUserId", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("reactorId", .text).notNull()
                t.column("emoji", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["ownerUserId", "messageId", "reactorId"])
                t.foreignKey(
                    ["ownerUserId", "messageId"],
                    references: "messages",
                    columns: ["ownerUserId", "id"],
                    onDelete: .cascade
                )
            }
            try db.create(
                index: "idx_reactions_owner_conversation",
                on: "message_reactions",
                columns: ["ownerUserId", "conversationId"]
            )
        }

        return migrator
    }
}
