import Foundation
import CryptoKit

/// Handles encrypting media before "upload" and decrypting it back to
/// memory for display. Decrypted bytes are never written to disk — only
/// the encrypted blob is cached (see `encryptedFilePath` on `MediaItem`).
final class MediaEncryptionService {
    private let cryptoService: CryptoService
    private let mediaRepository: MediaRepository
    private let apiClient: APIClientProtocol

    private var cacheDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("encrypted-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(cryptoService: CryptoService, mediaRepository: MediaRepository, apiClient: APIClientProtocol) {
        self.cryptoService = cryptoService
        self.mediaRepository = mediaRepository
        self.apiClient = apiClient
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
    }

    /// Encrypts raw image/video bytes with a fresh random key, "uploads"
    /// the ciphertext to the mock backend, and returns the small payload
    /// that should be sent as the message body.
    func prepareForSending(rawData: Data, thumbnail: Data?, mediaType: MediaType) async throws -> PreparedMedia {
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
        // require re-downloading.
        let localPath = cacheDirectory.appendingPathComponent(uploadResult.mediaId).path
        try encryptedFile.write(to: URL(fileURLWithPath: localPath))

        try mediaRepository.insert(MediaItem(
            id: uploadResult.mediaId,
            messageId: "", // filled in by caller once the Message row exists
            encryptedFilePath: localPath,
            encryptedThumbnail: encryptedThumbnail,
            fileSize: rawData.count,
            mediaType: mediaType,
            createdAt: Date()
        ))

        return PreparedMedia(mediaId: uploadResult.mediaId, messagePayload: payloadData, mediaType: mediaType, fileSize: rawData.count)
    }

    /// Given a decrypted message payload (already pulled through the
    /// Double Ratchet / local-storage decryption), fetches and decrypts the
    /// actual media bytes, entirely in memory.
    func decryptMedia(fromMessagePayload payloadData: Data) async throws -> Data {
        let payload = try JSONDecoder().decode(MediaKeyPayload.self, from: payloadData)
        let localPath = cacheDirectory.appendingPathComponent(payload.mediaId).path

        let encryptedFile: Data
        if FileManager.default.fileExists(atPath: localPath) {
            encryptedFile = try Data(contentsOf: URL(fileURLWithPath: localPath))
        } else {
            encryptedFile = try await apiClient.downloadMedia(mediaId: payload.mediaId)
            try encryptedFile.write(to: URL(fileURLWithPath: localPath))
        }

        let key = SymmetricKey(data: payload.key)
        return try AESGCM.open(ciphertext: encryptedFile, key: key)
    }
}

private struct MediaKeyPayload: Codable {
    let mediaId: String
    let key: Data
    let thumbnailKey: Data?
}
