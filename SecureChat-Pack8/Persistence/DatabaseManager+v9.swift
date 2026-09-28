import Foundation
import GRDB

// Migration v9, to be pasted into `DatabaseManager.migrator` immediately after
// `v8_alarms`, and its identifier added to `expectedMigrationIdentifiers`.
//
// Written here as a snippet rather than a separate registered function on
// purpose — a migration in its own file behind a "remember to wire this up"
// comment is exactly the mistake this project already made once with v6, where
// the registration was never added and the schema silently kept the primary key
// the migration existed to replace.
//
//        "v9_receipts_presence_invites",   ← add to expectedMigrationIdentifiers

/*
 migrator.registerMigration("v9_receipts_presence_invites") { db in

     // MARK: Receipts (feature #3)
     //
     // Two nullable timestamps on `messages` rather than a separate table.
     // A receipt is one-per-message-per-direction and is always read together
     // with the message, so a join would cost more than it saves.
     //
     // Nullable, not defaulted: "never delivered" and "delivered at epoch" are
     // different facts, and a NOT NULL default would make the difference
     // unrepresentable.
     try db.alter(table: "messages") { t in
         t.add(column: "deliveredAt", .datetime)
         t.add(column: "readAt", .datetime)
     }

     // MARK: Profiles (feature #4)
     //
     // Added to `users`, which is already the per-account contact store
     // (composite-keyed `(ownerUserId, id)` since v5), so avatars inherit the
     // same account isolation as pinned identity keys.
     try db.alter(table: "users") { t in
         t.add(column: "displayName", .text)
         t.add(column: "avatarFileName", .text)
         t.add(column: "profileUpdatedAt", .datetime)
     }

     // MARK: Invitations (feature #6)
     //
     // A conversation now has an explicit relationship state, so a chat can
     // exist locally — visible, openable — before the peer has accepted. That
     // is the whole point of the feature: you can see the thread you started
     // rather than it appearing only once they reply.
     //
     // Defaults to 'accepted' so every conversation that already exists keeps
     // working. Treating pre-existing chats as pending would lock users out of
     // their own history on upgrade.
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
 */

/// Where a conversation stands between the two people in it.
///
/// Stored as a string rather than an integer so a raw database dump stays
/// readable during debugging, and so adding a state later doesn't renumber the
/// existing ones.
enum ConversationRelationshipState: String, Codable, Equatable, DatabaseValueConvertible {
    /// We sent an invite and are waiting. Messages can be composed and are
    /// queued locally, but nothing is transmitted until they accept.
    case invitedByMe
    /// They invited us; we haven't answered. Their note is visible; their
    /// messages are not delivered until we accept.
    case invitedByThem
    /// Both sides agreed. Normal messaging.
    case accepted
    /// We declined, or they did. Kept rather than deleted so a declined
    /// invite doesn't simply reappear the next time they send one.
    case declined
    /// Legacy conversations from before invitations existed.
    case legacy

    var allowsSending: Bool {
        switch self {
        case .accepted, .legacy: return true
        case .invitedByMe, .invitedByThem, .declined: return false
        }
    }

    var explanation: String? {
        switch self {
        case .accepted, .legacy:
            return nil
        case .invitedByMe:
            return "Waiting for them to accept your invitation. You can write messages now — they'll send once it's accepted."
        case .invitedByThem:
            return "They've invited you to chat. Accept to start messaging."
        case .declined:
            return "This invitation was declined."
        }
    }
}
