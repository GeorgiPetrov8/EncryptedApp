import Foundation
import GRDB

/// Where a conversation stands between the two people in it (Pack 8, v9 schema).
///
/// Stored as a string so a raw database dump stays readable and adding a
/// state later doesn't renumber existing ones.
///
/// Note: v9 only adds the `relationshipState` column (default `'accepted'`).
/// `Conversation` doesn't expose it as a property yet and nothing gates sending
/// on it — that's the invitations feature itself, still to be built. Existing
/// code keeps working because GRDB ignores columns a record doesn't declare
/// and inserts fall back to the column default.
enum ConversationRelationshipState: String, Codable, Equatable, DatabaseValueConvertible {
    /// We sent an invite and are waiting. Messages are queued locally.
    case invitedByMe
    /// They invited us; we haven't answered.
    case invitedByThem
    /// Both sides agreed. Normal messaging.
    case accepted
    /// Declined — kept so a declined invite doesn't simply reappear.
    case declined
    /// Conversations from before invitations existed.
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
