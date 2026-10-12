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
    /// An envelope arrived but could not be decrypted (Bug #9).
    case undecryptable
}

/// A single message.
///
/// `encryptedContent` is NOT the Double Ratchet transport ciphertext — it's the
/// plaintext re-encrypted with the device-local storage key, because ratchet
/// message keys are single-use and can't re-decrypt history.
///
/// For text messages the plaintext is a `TextPayload` (JSON, may carry a reply);
/// older rows are raw UTF-8 and `TextPayload.decode` handles both.
struct Message: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"

    var id: String
    /// Which local account owns this row (Bug #10).
    var ownerUserId: String
    var conversationId: String
    var senderId: String
    var encryptedContent: Data
    var contentType: MessageContentType
    var deliveryStatus: DeliveryStatus
    var createdAt: Date
    var deliveredAt: Date?
    var readAt: Date?
    /// Set when the text was changed after sending (migration v10).
    var editedAt: Date?

    var isUndecryptable: Bool { deliveryStatus == .undecryptable }

    /// Media payloads must never be rendered as text (Bug #18).
    var carriesMediaPayload: Bool {
        contentType == .image || contentType == .video || contentType == .file
    }
}
