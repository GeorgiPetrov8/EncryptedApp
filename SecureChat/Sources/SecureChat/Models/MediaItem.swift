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
    var messageId: String
    var encryptedFilePath: String
    var encryptedThumbnail: Data?
    var fileSize: Int
    var mediaType: MediaType
    var createdAt: Date
}
