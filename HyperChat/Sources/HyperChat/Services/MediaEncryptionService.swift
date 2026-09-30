import Foundation
import CryptoKit
import os

/// The small JSON blob that travels as a media message's *body*, through the normal
/// Double Ratchet channel — the spec's "share the decryption key via message
/// encryption".
///
/// FIX: was `private` at file scope, which made the receive-side fix impossible to
/// write: `MessagingService` had to read `mediaId` out of a decrypted payload to
/// create the recipient's `MediaItem`, and could not see this type at all.
///
/// It is deliberately `internal` rather than public-by-habit, and deliberately *not*
/// `CustomStringConvertible`: `key` is raw AES key material, and the whole point of
/// Bug #18 was that this struct must never be rendered anywhere a person can see it.
struct MediaKeyPayload: Codable {
    let mediaId: String
    let key: Data
    let thumbnailKey: Data?
    let mediaType: MediaType

    // Voice-message metadata.
    // nil for images, videos and documents.
    let duration: TimeInterval?
    let waveform: [Float]?
}

/// Handles encrypting media before "upload" and decrypting it back to
/// memory for display. Decrypted bytes are never written to disk — only
/// the encrypted blob is cached (see `encryptedFilePath` on `MediaItem`).
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
        /// The row to persist, handed back instead of inserted here (Bug #13).
        let pendingMediaItem: MediaItem
    }

    // MARK: Sending

    /// Encrypts raw image/video bytes with a fresh random key, "uploads" the
    /// ciphertext, and returns the small payload that should be sent as the message
    /// body. Deliberately performs no database writes.
    func prepareForSending(
        rawData: Data,
        thumbnail: Data?,
        mediaType: MediaType,
        duration: TimeInterval? = nil,
        waveform: [Float]? = nil,
        ownerUserId: String
    ) async throws -> PreparedMedia {
        let inspection = AttachmentPolicy.inspect(
            data: rawData,
            declaredExtension: nil
        )

        guard case .success(let accepted) = inspection else {
            if case .failure(let rejection) = inspection {
                throw rejection
            }

            throw AttachmentPolicy.Rejection.unrecognisedFormat
        }

        let expectedMediaType: MediaType

        switch accepted.category {
        case .image:
            expectedMediaType = .image

        case .video:
            expectedMediaType = .video

        case .audio:
            expectedMediaType = .audio

        case .document:
            expectedMediaType = .document
        }

        guard mediaType == expectedMediaType else {
            throw AttachmentPolicy.Rejection.unrecognisedFormat
        }
        
        if mediaType == .audio {
            guard let duration, duration > 0 else {
                throw AttachmentPolicy.Rejection.unrecognisedFormat
            }

            guard let waveform, !waveform.isEmpty else {
                throw AttachmentPolicy.Rejection.unrecognisedFormat
            }
        }

        var encryptedThumbnail: Data?
        var thumbnailKeyData: Data?
        
        if let thumbnail {
            let thumbnailInspection = AttachmentPolicy.inspect(
                data: thumbnail,
                declaredExtension: "jpg"
            )

            guard case .success = thumbnailInspection else {
                if case .failure(let rejection) = thumbnailInspection {
                    throw rejection
                }

                throw AttachmentPolicy.Rejection.unrecognisedFormat
            }
        }
        
        let fileKey = AESGCM.randomKey()
        let encryptedFile = try AESGCM.seal(plaintext: rawData, key: fileKey)

        let uploadResult = try await apiClient.uploadMedia(data: encryptedFile)

        
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

        // Cache our own encrypted copy locally too, so re-viewing doesn't require
        // re-downloading. Protected location, bounded size (Bug #23).
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

    /// FIX: builds the recipient's own `MediaItem` for an inbound media message.
    ///
    /// This side had no equivalent of `prepareForSending`, so the recipient ended up
    /// with a `Message` row and no media row — leaving their cached blob unowned and
    /// therefore deletable by the *sender's* cleanup. See the note on
    /// `MessageRepository.insertIfNotProcessed`.
    ///
    /// Two fields are necessarily provisional at this point:
    ///   - `encryptedFilePath` names the cache slot the blob *will* occupy. The file
    ///     doesn't exist until the user actually views the message; the row records
    ///     a reference, not the presence of bytes. `MediaCacheStore.contains` is what
    ///     answers "is it downloaded?".
    ///   - `fileSize` is 0 until then, and is filled in by `decryptMedia` on first
    ///     download. Recording a guess would be worse than recording nothing.
    ///
    /// The thumbnail stays `nil`: `prepareForSending` keeps the encrypted thumbnail in
    /// the sender's row only and never puts it on the wire, so there is nothing for
    /// the recipient to store.
    func makeReceivedMediaItem(
        payloadData: Data,
        messageId: String,
        ownerUserId: String,
        createdAt: Date
    ) throws -> MediaItem {
        let payload = try JSONDecoder().decode(
            MediaKeyPayload.self,
            from: payloadData
        )

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

    /// Given a decrypted message payload, fetches and decrypts the actual media
    /// bytes, entirely in memory.
    ///
    /// - Parameter ownerUserId: when supplied, the row's `fileSize` is backfilled
    ///   after a download. Optional so existing call sites that only want the bytes
    ///   don't have to care.
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

        let inspection = AttachmentPolicy.inspect(
            data: plaintext,
            declaredExtension: nil
        )

        guard case .success = inspection else {
            cache.remove(mediaId: payload.mediaId)

            if case .failure(let rejection) = inspection {
                throw rejection
            }

            throw AttachmentPolicy.Rejection.unrecognisedFormat
        }
        
        if let ownerUserId {
            // Now that the bytes exist, the provisional 0 from
            // `makeReceivedMediaItem` can be replaced with the real figure.
            try? mediaRepository.updateFileSize(
                mediaId: payload.mediaId,
                ownerUserId: ownerUserId,
                fileSize: plaintext.count
            )
        }

        return plaintext
    }

    // MARK: Deletion

    /// Scoped by owner: unscoped, deleting your own message's attachment also deleted
    /// the file backing the other local account's copy.
    func deleteMedia(forMessageId messageId: String, ownerUserId: String) throws {
        let paths = try mediaRepository.delete(messageId: messageId, ownerUserId: ownerUserId)
        cache.remove(paths: paths)
    }

    /// Used by account deletion: removes this account's rows and unlinks the blobs.
    ///
    /// Paths are computed before the delete so `exclusivelyOwnedPaths` can still see
    /// the rows; the filter matters because the other account may reference the same
    /// blob.
    func deleteAllMedia(ownerUserId: String) throws {
        let exclusive = try mediaRepository.exclusivelyOwnedPaths(ownerUserId: ownerUserId)
        _ = try mediaRepository.deleteAll(ownerUserId: ownerUserId)
        cache.remove(paths: exclusive)
    }

    /// Logout evicts only this account's blobs, and only those no other account
    /// references. Database rows are left intact: logout must not destroy data.
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
