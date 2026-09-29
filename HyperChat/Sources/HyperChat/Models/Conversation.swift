import Foundation
import CryptoKit
import GRDB

enum RelationshipState: String, Codable, Hashable {
    case invitedByMe
    case invitedByThem
    case accepted
    case declined

    var allowsSending: Bool {
        self == .accepted
    }
}

/// A conversation between two (or, in a future group-chat extension, more)
/// participants. `participantIds` is stored as JSON automatically by GRDB's
/// Codable-record support, since arrays aren't a native SQLite column type.
struct Conversation: Codable, Identifiable, Equatable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversations"

    var id: String
    /// Which local account owns this conversation (Bug #10).
    var ownerUserId: String
    var participantIds: [String]
    var isGroup: Bool
    var createdAt: Date
    
    var relationshipState: RelationshipState
    var inviteNote: String?
    var inviteSentAt: Date?
    var inviteRespondedAt: Date?

    /// FIX (Bug #15): denormalised "last activity" timestamp.
    ///
    /// `fetchAllSortedByRecentActivity` sorted by `createdAt` despite its name, so a
    /// conversation with a new message never rose to the top. The repository now
    /// computes ordering from the messages table, and this column is maintained
    /// alongside it so the common path doesn't need the aggregate at all.
    var lastMessageAt: Date?

    init(
        id: String,
        ownerUserId: String,
        participantIds: [String],
        isGroup: Bool,
        createdAt: Date,
        lastMessageAt: Date? = nil,
        relationshipState: RelationshipState = .accepted,
        inviteNote: String? = nil,
        inviteSentAt: Date? = nil,
        inviteRespondedAt: Date? = nil
    ) {
        self.id = id
        self.ownerUserId = ownerUserId
        self.participantIds = participantIds
        self.isGroup = isGroup
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.relationshipState = relationshipState
        self.inviteNote = inviteNote
        self.inviteSentAt = inviteSentAt
        self.inviteRespondedAt = inviteRespondedAt
    }

    /// Convenience for 1:1 chats: the other participant, given my own id.
    func otherParticipant(myUserId: String) -> String? {
        participantIds.first { $0 != myUserId }
    }

    /// Effective sort key — falls back to creation time for empty conversations.
    var lastActivityAt: Date { lastMessageAt ?? createdAt }

    /// FIX (Bug #14): both sides derive the same conversation id.
    ///
    /// The id used to be `UUID().uuidString`, generated locally by whoever started
    /// the conversation. If both users pressed "new chat" before exchanging a
    /// message, each created a different id for the same pair and the history split
    /// permanently in two — `findDirectConversation` only helped the side that
    /// happened to look first.
    ///
    /// Sorting the participant ids before hashing is what makes this symmetric.
    static func deterministicId(participantIds: [String]) -> String {
        let canonical = participantIds.sorted().joined(separator: ":")
        let digest = SHA256.hash(data: Data("HyperChat Conversation v1:\(canonical)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
