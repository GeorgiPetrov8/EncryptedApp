import Foundation
import GRDB

enum MediaType: String, Codable, DatabaseValueConvertible {
    case image
    case video
}

/// Metadata for an encrypted media file. The actual encrypted bytes live on
/// disk at `encryptedFilePath` (never written to disk in decrypted form —
/// decryption happens in memory only, at display time). The per-file AES key
/// is never stored here; it travels inside the message's encrypted content,
/// exactly like the original spec's "share the key via message encryption".
struct MediaItem: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "media"

    var id: String
    /// FIX (Bug #13): always a real message id now.
    ///
    /// `MediaEncryptionService.prepareForSending` used to insert with `messageId: ""`
    /// and a comment saying the caller would fill it in — nobody did. The column is
    /// `NOT NULL` with a foreign key to `messages(id)`, so with GRDB's foreign keys
    /// enabled the insert simply failed; without them it left an orphan row that
    /// `fetch(messageId:)` could never find.
    ///
    /// The flow is now inverted: the message row is created first and its id is
    /// passed in, so the media row always has a valid parent.
    var messageId: String
    /// FIX (Bug #23): scopes cached files to an account so `deleteAccount` and
    /// logout can clear exactly the right ones.
    var ownerUserId: String
    var encryptedFilePath: String
    var encryptedThumbnail: Data?
    var fileSize: Int
    var mediaType: MediaType
    var createdAt: Date
}
