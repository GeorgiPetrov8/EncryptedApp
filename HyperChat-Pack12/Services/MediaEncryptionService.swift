import Foundation
import CryptoKit
import os

/// The small JSON blob that travels as a media message's body, through the
/// Double Ratchet channel. Never rendered: `key` is raw AES key material.
struct MediaKeyPayload: Codable {
    let mediaId: String
    let key: Data
    let thumbnailKey: Data?
    let mediaType: MediaType
    /// Voice-message metadata; nil for images, videos and documents.
    let duration: TimeInterval?
    let waveform: [Float]?
}

/// Encrypts media before upload and decrypts it back to memory for display.
/// Decrypted bytes are never written to the cache — only the encrypted blob.
final class MediaEncryptionService {
    private let cryptoService: CryptoService
    private let mediaRepository: MediaRepository
    private let apiClient: APIClientProtocol
    private let cache: MediaCacheStore
    private let logger = Logger(subsystem: "com.HyperChat", category: "media")

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
        let messagePayload: Data
        let mediaType: MediaType
        let fileSize: Int
        let pendingMediaItem: MediaItem
    }

    // MARK: Sending

    func prepareForSending(
        rawData: Data,
        thumbnail: Data?,
        mediaType: MediaType,
        duration: TimeInterval? = nil,
        waveform: [Float]? = nil,
        ownerUserId: String
    ) async throws -> PreparedMedia {
        // FIX: one check that knows what the attachment is supposed to be.
        // The previous version called `inspect(declaredExtension: nil)`, which
        // can't recognise plain-text documents (they have no signature — only
        // the extension marks them), so every .txt/.csv failed here even
        // though the picker had already accepted it.
        if case .failure(let rejection) = AttachmentPolicy.checkReceived(rawData, expected: mediaType) {
            throw rejection
        }

        if mediaType == .audio {
            guard let duration, duration > 0, let waveform, !waveform.isEmpty else {
                throw AttachmentPolicy.Rejection.unrecognisedFormat
            }
        }

        if let thumbnail,
           case .failure(let rejection) = AttachmentPolicy.inspect(data: thumbnail, declaredExtension: "jpg") {
            throw rejection
        }

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
            thumbnailKey: thumbnailKeyData,
            mediaType: mediaType,
            duration: mediaType == .audio ? duration : nil,
            waveform: mediaType == .audio ? waveform : nil
        )
        let payloadData = try JSONEncoder().encode(payload)

        let localURL = try cache.write(encryptedFile, mediaId: uploadResult.mediaId)
        cache.prune()

        let item = MediaItem(
            id: uploadResult.mediaId,
            messageId: "", // set by MessageRepository inside the transaction
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

    // MARK: Receiving

    func makeReceivedMediaItem(
        payloadData: Data,
        messageId: String,
        ownerUserId: String,
        createdAt: Date
    ) throws -> MediaItem {
        let payload = try JSONDecoder().decode(MediaKeyPayload.self, from: payloadData)
        let expectedURL = try cache.url(forMediaId: payload.mediaId)
        return MediaItem(
            id: payload.mediaId,
            messageId: messageId,
            ownerUserId: ownerUserId,
            encryptedFilePath: expectedURL.path,
            encryptedThumbnail: nil,
            fileSize: 0,
            mediaType: payload.mediaType,
            createdAt: createdAt
        )
    }

    /// Fetches and decrypts media bytes, entirely in memory, then checks them
    /// on this (the recipient's) device — the check a modified sender can't skip.
    func decryptMedia(fromMessagePayload payloadData: Data, ownerUserId: String? = nil) async throws -> Data {
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
        let plaintext = try AESGCM.open(ciphertext: encryptedFile, key: key)

        // FIX: checked against the type the message claims (a "photo" must be
        // an image), and plain-text documents are no longer rejected.
        if case .failure(let rejection) = AttachmentPolicy.checkReceived(plaintext, expected: payload.mediaType) {
            cache.remove(mediaId: payload.mediaId)
            throw rejection
        }

        if let ownerUserId {
            try? mediaRepository.updateFileSize(
                mediaId: payload.mediaId,
                ownerUserId: ownerUserId,
                fileSize: plaintext.count
            )
        }
        return plaintext
    }

    // MARK: Deletion

    func deleteMedia(forMessageId messageId: String, ownerUserId: String) throws {
        let paths = try mediaRepository.delete(messageId: messageId, ownerUserId: ownerUserId)
        cache.remove(paths: paths)
    }

    func deleteAllMedia(ownerUserId: String) throws {
        let exclusive = try mediaRepository.exclusivelyOwnedPaths(ownerUserId: ownerUserId)
        _ = try mediaRepository.deleteAll(ownerUserId: ownerUserId)
        cache.remove(paths: exclusive)
    }

    func clearCache(ownerUserId: String) {
        do {
            let exclusive = try mediaRepository.exclusivelyOwnedPaths(ownerUserId: ownerUserId)
            cache.remove(paths: exclusive)
            logger.debug("Evicted \(exclusive.count, privacy: .public) cached media files on logout")
        } catch {
            logger.error("Couldn't evict this account's media cache; leaving it in place")
        }
    }

    func pruneCache() {
        cache.prune()
    }
}
