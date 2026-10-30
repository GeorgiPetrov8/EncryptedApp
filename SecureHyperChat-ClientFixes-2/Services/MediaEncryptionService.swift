import Foundation
import CryptoKit
import os

/// The small JSON blob that travels as a media message's body, through the
/// Double Ratchet channel. Never rendered: `key` is raw AES key material.
///
/// `thumbnailKey` is kept for wire compatibility with older versions; no
/// thumbnail is uploaded or read (F7).
struct MediaKeyPayload: Codable {
    let mediaId: String
    let key: Data
    let thumbnailKey: Data?
    let mediaType: MediaType
    /// Voice-message metadata; nil for images, videos and documents.
    let duration: TimeInterval?
    let waveform: [Float]?
}

enum MediaPayloadError: LocalizedError {
    case invalidPayload
    var errorDescription: String? { "This attachment is malformed." }
}

/// Encrypts media before upload and decrypts it back to memory for display.
/// Decrypted bytes are never written to the cache — only the encrypted blob.
final class MediaEncryptionService {
    private let cryptoService: CryptoService
    private let mediaRepository: MediaRepository
    private let apiClient: APIClientProtocol
    private let cache: MediaCacheStore
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "media")

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

    /// FIX (S31): every field of a received payload is checked before use — the
    /// sender wrote it. A 32-byte key and a UUID media id, nothing else.
    static func decodeValidated(_ data: Data) throws -> MediaKeyPayload {
        let payload = try JSONDecoder().decode(MediaKeyPayload.self, from: data)
        guard SafeIdentifier.isMediaId(payload.mediaId), payload.key.count == 32 else {
            throw MediaPayloadError.invalidPayload
        }
        if let waveform = payload.waveform, waveform.count > 1_000 { throw MediaPayloadError.invalidPayload }
        if let duration = payload.duration, !(0...3_600).contains(duration) { throw MediaPayloadError.invalidPayload }
        return payload
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
        if case .failure(let rejection) = AttachmentPolicy.checkReceived(rawData, expected: mediaType) {
            throw rejection
        }
        if mediaType == .audio {
            guard let duration, duration > 0, let waveform, !waveform.isEmpty else {
                throw AttachmentPolicy.Rejection.unrecognisedFormat
            }
        }

        let fileKey = AESGCM.randomKey()
        let encryptedFile = try AESGCM.seal(plaintext: rawData, key: fileKey)
        let uploadResult = try await apiClient.uploadMedia(data: encryptedFile)
        guard SafeIdentifier.isMediaId(uploadResult.mediaId) else { throw MediaPayloadError.invalidPayload }

        let payload = MediaKeyPayload(
            mediaId: uploadResult.mediaId,
            key: fileKey.withUnsafeBytes { Data($0) },
            thumbnailKey: nil,
            mediaType: mediaType,
            duration: mediaType == .audio ? duration : nil,
            waveform: mediaType == .audio ? waveform : nil
        )
        let payloadData = try JSONEncoder().encode(payload)
        let localURL = try cache.write(encryptedFile, mediaId: uploadResult.mediaId)

        let item = MediaItem(
            id: uploadResult.mediaId,
            messageId: "", // set by MessageRepository inside the transaction
            ownerUserId: ownerUserId,
            encryptedFilePath: localURL.path,
            encryptedThumbnail: nil,
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
        let payload = try Self.decodeValidated(payloadData)
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

    /// Fetches and decrypts media bytes, entirely in memory, then checks them on
    /// this (the recipient's) device.
    func decryptMedia(fromMessagePayload payloadData: Data, ownerUserId: String? = nil) async throws -> Data {
        let payload = try Self.decodeValidated(payloadData)

        let encryptedFile: Data
        if cache.contains(mediaId: payload.mediaId) {
            encryptedFile = try cache.read(mediaId: payload.mediaId)
        } else {
            encryptedFile = try await apiClient.downloadMedia(mediaId: payload.mediaId)
            try cache.write(encryptedFile, mediaId: payload.mediaId)
        }

        let plaintext = try AESGCM.open(ciphertext: encryptedFile, key: SymmetricKey(data: payload.key))

        if case .failure(let rejection) = AttachmentPolicy.checkReceived(plaintext, expected: payload.mediaType) {
            cache.remove(mediaId: payload.mediaId)
            throw rejection
        }
        // R22: a "photo" whose declared size would decode into gigabytes is refused
        // here, before any view tries to draw it.
        if payload.mediaType == .image, !ImageSafety.isAcceptable(plaintext) {
            throw AttachmentPolicy.Rejection.unrecognisedFormat
        }

        if let ownerUserId {
            try? mediaRepository.updateFileSize(mediaId: payload.mediaId, ownerUserId: ownerUserId, fileSize: plaintext.count)
        }
        return plaintext
    }

    // MARK: Deletion

    func deleteMedia(forMessageId messageId: String, ownerUserId: String) throws {
        let paths = try mediaRepository.delete(messageId: messageId, ownerUserId: ownerUserId)
        cache.remove(paths: paths)
    }

    /// Account deletion only.
    func deleteAllMedia(ownerUserId: String) throws {
        let exclusive = try mediaRepository.exclusivelyOwnedPaths(ownerUserId: ownerUserId)
        _ = try mediaRepository.deleteAll(ownerUserId: ownerUserId)
        cache.remove(paths: exclusive)
    }

    /// FIX (R4): logging out no longer deletes media. The encrypted files were
    /// the only copy once the server had discarded them; signing out and back in
    /// left every photo as "Couldn't load". They are unreadable without this
    /// account's keys anyway. Only in-memory decrypted images are dropped.
    func clearCache(ownerUserId: String) {
        DecryptedMediaCache.shared.removeAll()
    }

    func pruneCache() {
        cache.prune()
    }

    func cacheSizeBytes() -> Int {
        cache.totalBytes()
    }
}
