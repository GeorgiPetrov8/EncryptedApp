import Foundation
import GRDB

enum MessageContentType: String, Codable, DatabaseValueConvertible {
    case text
    case image
    case video
    case file
}

enum DeliveryStatus: String, Codable, DatabaseValueConvertible {
    case sending
    case sent
    case delivered
    case read
    case failed
    /// FIX (Bug #9): an envelope arrived but could not be decrypted (tampered,
    /// replayed out of a broken session, or a ratchet desync). Previously such a
    /// message simply never appeared and the error was swallowed by `try?`, leaving
    /// an invisible hole in the conversation.
    case undecryptable
}

/// A single message.
///
/// IMPORTANT ARCHITECTURE NOTE:
/// `encryptedContent` is NOT the Double Ratchet transport ciphertext.
/// Double Ratchet message keys are used once and then discarded for forward
/// secrecy, so they can't be used to re-decrypt history later. Instead:
///   - Outgoing: plaintext -> Double Ratchet (sent over the wire) AND
///               plaintext -> local-storage AES-GCM key -> stored here.
///   - Incoming: wire ciphertext -> Double Ratchet decrypt -> plaintext ->
///               local-storage AES-GCM key -> stored here.
struct Message: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"

    var id: String
    /// FIX (Bug #10): which local account owns this row.
    ///
    /// Namespacing the Keychain alone does not satisfy the acceptance criterion —
    /// without this column, a second account's `fetchMessages` would return the
    /// first account's rows (and fail to decrypt them, since storage keys now
    /// differ per account).
    var ownerUserId: String
    var conversationId: String
    var senderId: String
    var encryptedContent: Data
    var contentType: MessageContentType
    var deliveryStatus: DeliveryStatus
    var createdAt: Date
    var deliveredAt: Date?
    var readAt: Date?

    /// True when this row is a placeholder standing in for an envelope that failed
    /// to decrypt, rather than real content.
    var isUndecryptable: Bool { deliveryStatus == .undecryptable }

    /// FIX (Bug #18): media payloads must never be rendered as text.
    ///
    /// The body of a media message is a `MediaKeyPayload` JSON blob containing the
    /// base64 per-file AES key. `ConversationListViewModel` stringified it directly
    /// into the chat list.
    var carriesMediaPayload: Bool {
        contentType == .image || contentType == .video || contentType == .file
    }
}
