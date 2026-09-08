import Foundation
import CryptoKit

/// Handles encrypting media before "upload" and decrypting it back to
/// memory for display. Decrypted bytes are never written to disk — only
/// the encrypted blob is cached (see `encryptedFilePath` on `MediaItem`).
final class MediaEncryptionService {
    private let cryptoService: CryptoService
    private let mediaRepository: MediaRepository
    private let apiClient: APIClientProtocol
    private let cache: MediaCacheStore

    init(
        cryptoService: CryptoService,
        mediaRepository: MediaRepository,
        apiClient: APIClientProtocol,
        cache: MediaCacheStore = MediaCacheStore()
    ) {
        self.cryptoService = cryptoService
        self.mediaRepository = mediaRepository
        self.apiClient = apiClient
        self.cache = cache
    }

    struct PreparedMedia {
        let mediaId: String
        /// JSON payload — {mediaId, key, thumbnailKey} — meant to be sent
        /// as the *message body* through the normal Double Ratchet channel,
        /// exactly like the spec's "share the decryption key via message
        /// encryption".
        let messagePayload: Data
        let mediaType: MediaType
        let fileSize: Int
        /// FIX (Bug #13): the row to persist, handed back instead of inserted here.
        ///
        /// This service used to insert it directly with `messageId: ""` and a comment
        /// saying the caller would fill it in later — nothing ever did. Because
        /// `media.messageId` is `NOT NULL` with a foreign key to `messages(id)`, that
        /// insert either failed outright with foreign keys enabled or left an orphan
        /// row `fetch(messageId:)` could never return.
        ///
        /// `MessagingService` now creates the message row first and writes both in a
        /// single transaction via `MessageRepository.insert(_:media:)`.
        let pendingMediaItem: MediaItem
    }

    /// Encrypts raw image/video bytes with a fresh random key, "uploads"
    /// the ciphertext to the mock backend, and returns the small payload
    /// that should be sent as the message body.
    ///
    /// Deliberately performs no database writes.
    func prepareForSending(
        rawData: Data,
        thumbnail: Data?,
        mediaType: MediaType,
        ownerUserId: String
    ) async throws -> PreparedMedia {
        let fileKey = AESGCM.randomKey()
        let encryptedFile = try AESGCM.seal(plaintext: rawData, key: fileKey)

        let uploadResult = try await apiClient.uploadMedia(data: encryptedFile)

        var encryptedThumbnail: Data?
        var thumbnailKeyData: Data?
        if let thumbnail {
            let thumbKey = AESGCM.randomKey()
            encryptedThumbnail = try AESGCM.seal(plaintext: thumbnail, key: thumbKey)
            thumbnailKeyData = thumbKey.withUnsafeBytes { Data($0) }
        }

        let payload = MediaKeyPayload(
            mediaId: uploadResult.mediaId,
            key: fileKey.withUnsafeBytes { Data($0) },
            thumbnailKey: thumbnailKeyData
        )
        let payloadData = try JSONEncoder().encode(payload)

        // Cache our own encrypted copy locally too, so re-viewing doesn't
        // require re-downloading. FIX (Bug #23): protected location, bounded size.
        let localURL = try cache.write(encryptedFile, mediaId: uploadResult.mediaId)
        cache.prune()

        let item = MediaItem(
            id: uploadResult.mediaId,
            messageId: "", // set by MessageRepository.insert(_:media:) inside the transaction
            ownerUserId: ownerUserId,
            encryptedFilePath: localURL.path,
            encryptedThumbnail: encryptedThumbnail,
            fileSize: rawData.count,
            mediaType: mediaType,
            createdAt: Date()
        )

        return PreparedMedia(
            mediaId: uploadResult.mediaId,
            messagePayload: payloadData,
            mediaType: mediaType,
            fileSize: rawData.count,
            pendingMediaItem: item
        )
    }

    /// Given a decrypted message payload (already pulled through the
    /// Double Ratchet / local-storage decryption), fetches and decrypts the
    /// actual media bytes, entirely in memory.
    func decryptMedia(fromMessagePayload payloadData: Data) async throws -> Data {
        let payload = try JSONDecoder().decode(MediaKeyPayload.self, from: payloadData)

        let encryptedFile: Data
        if cache.contains(mediaId: payload.mediaId) {
            encryptedFile = try cache.read(mediaId: payload.mediaId)
        } else {
            encryptedFile = try await apiClient.downloadMedia(mediaId: payload.mediaId)
            try cache.write(encryptedFile, mediaId: payload.mediaId)
            cache.prune()
        }

        let key = SymmetricKey(data: payload.key)
        return try AESGCM.open(ciphertext: encryptedFile, key: key)
    }

    /// FIX (Bug #23): removes rows *and* the blobs they point at.
    func deleteMedia(forMessageId messageId: String) throws {
        let paths = try mediaRepository.delete(messageId: messageId)
        cache.remove(paths: paths)
    }

    func deleteAllMedia(ownerUserId: String) throws {
        let paths = try mediaRepository.deleteAll(ownerUserId: ownerUserId)
        cache.remove(paths: paths)
    }

    /// Called on logout so the next account on this device starts clean.
    func clearCache() {
        cache.removeAll()
    }

    func pruneCache() {
        cache.prune()
    }
}

private struct MediaKeyPayload: Codable {
    let mediaId: String
    let key: Data
    let thumbnailKey: Data?
}
