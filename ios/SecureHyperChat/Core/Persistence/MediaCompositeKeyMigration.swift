import Foundation
import GRDB

/// Migration v6 — `media` gets a composite primary key too.
///
/// Add this registration to `DatabaseManager.migrator`, immediately after
/// `v5_composite_primary_keys`. It is kept in its own file only so the pack 5 delta
/// stays reviewable; fold it into `DatabaseManager.swift` when you apply it.
///
/// ---
///
/// FIX: a defect introduced by pack 4, found while writing the shared-blob test.
///
/// v5 left `media.id` as a single-column primary key, justified in its own comment as
/// "a server-assigned upload id, globally unique — only the parent reference needs an
/// owner." The premise is true and the conclusion doesn't follow.
///
/// Global uniqueness of the *identifier* is not the question. The question is how many
/// rows reference it, and the answer is one per account: when Alice sends Bob a photo,
/// both cache the same blob under the same `mediaId`, so both need a `MediaItem` row.
/// With a single-column key the second insert fails with a primary-key conflict —
/// exactly the failure v5 fixed for `messages`, reintroduced one table over.
///
/// The composite key is also what makes `exclusivelyOwnedPaths` meaningful: asking
/// "does another account still reference this blob?" presupposes that two rows can
/// share an id.
enum MediaCompositeKeyMigration {

    static func register(in migrator: inout DatabaseMigrator) {
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
    }
}
