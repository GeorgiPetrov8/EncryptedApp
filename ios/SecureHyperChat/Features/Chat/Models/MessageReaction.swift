import Foundation
import GRDB

/// One person's reaction to one message, as seen by one local account.
///
/// Removing a reaction keeps the row with an empty `emoji` (a tombstone), so
/// an older "add" arriving late can't bring the reaction back.
struct MessageReaction: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message_reactions"

    var ownerUserId: String
    var conversationId: String
    var messageId: String
    var reactorId: String
    /// Empty = removed.
    var emoji: String
    var updatedAt: Date
}

/// What the chat shows under a message: one capsule per emoji.
struct ReactionSummary: Identifiable, Equatable {
    let emoji: String
    let count: Int
    let includesMe: Bool
    var id: String { emoji }
}
