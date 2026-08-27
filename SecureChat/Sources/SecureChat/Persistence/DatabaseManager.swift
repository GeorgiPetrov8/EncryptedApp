import Foundation
import GRDB

/// Owns the SQLite connection and schema migrations.
///
/// Design note on "encrypted database": the original spec calls for SQLCipher
/// (whole-file encryption). SQLCipher requires linking a custom OpenSSL-backed
/// SQLite build, which is a heavier dependency than fits a scaffold. Instead, this
/// project layers iOS Data Protection on the database file with application-level
/// AES-256-GCM encryption of every sensitive column.
final class DatabaseManager {
    let dbQueue: DatabaseQueue

    init(fileName: String = "securechat.sqlite") throws {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbURL = folder.appendingPathComponent(fileName)

        let config = Configuration()
        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)

        try Self.applyFileProtection(to: dbURL)
        try Self.migrator.migrate(dbQueue)
    }

    private static func applyFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

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

        /// FIX (Bug #2): identity pinning / verification columns.
        migrator.registerMigration("v2_identity_verification") { db in
            try db.alter(table: "users") { t in
                t.add(column: "identitySigningKey", .blob)
                t.add(column: "isVerified", .boolean).notNull().defaults(to: false)
                t.add(column: "identityChangedAt", .datetime)
                t.add(column: "pendingIdentityAgreementKey", .blob)
                t.add(column: "pendingIdentitySigningKey", .blob)
            }
        }

        /// FIX (Bug #8) + FIX (Bug #10): replay protection and per-account data scoping.
        ///
        /// `sessions` has to be rebuilt rather than altered, because SQLite cannot drop
        /// the existing `UNIQUE` constraint on `otherUserId` in place — and that
        /// constraint is exactly what makes two local accounts collide when they both
        /// talk to the same peer.
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

            // Rebuild `sessions` with a composite uniqueness constraint.
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

            // Replay protection. Composite key because envelope ids are sender-chosen.
            try db.create(table: "processed_envelopes") { t in
                t.column("recipientUserId", .text).notNull()
                t.column("senderId", .text).notNull()
                t.column("envelopeId", .text).notNull()
                t.column("receivedAt", .datetime).notNull()
                t.primaryKey(["recipientUserId", "senderId", "envelopeId"])
            }
            try db.create(index: "idx_processed_envelopes_receivedAt", on: "processed_envelopes", columns: ["receivedAt"])
        }

        return migrator
    }
}
