import Foundation
import GRDB

/// A conversation between two (or, in a future group-chat extension, more)
/// participants. `participantIds` is stored as JSON automatically by GRDB's
/// Codable-record support, since arrays aren't a native SQLite column type.
struct Conversation: Codable, Identifiable, Equatable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversations"

    var id: String
    /// FIX (Bug #10): which local account owns this conversation.
    ///
    /// `fetchAllSortedByRecentActivity()` previously returned every row in the table,
    /// so after registering a second account on the same device that account saw the
    /// first account's conversation list.
    var ownerUserId: String
    var participantIds: [String]
    var isGroup: Bool
    var createdAt: Date

    /// Convenience for 1:1 chats: the other participant, given my own id.
    func otherParticipant(myUserId: String) -> String? {
        participantIds.first { $0 != myUserId }
    }
}
