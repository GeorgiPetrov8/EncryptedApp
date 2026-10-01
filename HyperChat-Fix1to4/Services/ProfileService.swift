import Foundation
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import UIKit
import os

/// Profile pictures (and display name), shared peer-to-peer.
///
/// The avatar is encrypted on the device with a fresh AES key, uploaded as an
/// opaque blob, and the `{mediaId, key}` pair travels to each contact inside a
/// ratchet-encrypted `.profile` envelope. The server stores an unreadable blob
/// and never learns whose face it is.
///
/// Sharing happens:
///   - to every accepted contact when the avatar changes;
///   - lazily to a contact who hasn't got the current version yet, when their
///     chat is opened or a message from them arrives.
@MainActor
final class ProfileService: ObservableObject {

    /// Bumped on any avatar change, so views showing avatars refresh.
    @Published private(set) var version = 0
    @Published private(set) var isUpdating = false

    private let userRepository: UserRepository
    private let conversationRepository: ConversationRepository
    private let authService: AuthService
    private let apiClient: APIClientProtocol
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.HyperChat", category: "profile")

    private var sendHandler: ((ProfilePayload, Conversation) async throws -> Void)?
    private var imageCache: [String: Data] = [:]
    private var inFlight: Set<String> = []

    /// 512 px is sharp at the largest size shown (120 pt @3x ≈ 360 px) and keeps
    /// the blob small (~40–80 KB).
    private static let avatarPixelSize: CGFloat = 512
    /// Inbound avatars larger than this are rejected rather than stored.
    private static let maxAvatarBytes = 2 * 1024 * 1024

    /// What we last published, so a new contact gets the same blob without a
    /// re-upload.
    private struct Published: Codable {
        let avatarMediaId: String?
        let avatarKey: Data?
        let updatedAt: Date
    }

    init(
        userRepository: UserRepository,
        conversationRepository: ConversationRepository,
        authService: AuthService,
        apiClient: APIClientProtocol,
        defaults: UserDefaults = .standard
    ) {
        self.userRepository = userRepository
        self.conversationRepository = conversationRepository
        self.authService = authService
        self.apiClient = apiClient
        self.defaults = defaults
    }

    func setSendHandler(_ handler: @escaping (ProfilePayload, Conversation) async throws -> Void) {
        sendHandler = handler
    }

    // MARK: Reading

    func myAvatarData() -> Data? {
        guard let me = authService.currentUserId else { return nil }
        return avatarData(for: me)
    }

    func avatarData(for userId: String) -> Data? {
        guard let owner = authService.currentUserId,
              let user = try? userRepository.fetch(ownerUserId: owner, id: userId),
              let fileName = user.avatarFileName else { return nil }
        if let cached = imageCache[fileName] { return cached }
        guard let url = avatarURL(fileName: fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        imageCache[fileName] = data
        return data
    }

    // MARK: Changing my avatar

    func setMyAvatar(imageData raw: Data) async throws {
        guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
        isUpdating = true
        defer { isUpdating = false }

        guard let jpeg = Self.downsample(raw, maxPixelSize: Self.avatarPixelSize) else {
            throw ProfileError.invalidImage
        }

        // Local copy first, so the user's own avatar updates immediately even
        // if the upload fails.
        let fileName = "\(me)_\(me).jpg"
        try writeAvatar(jpeg, fileName: fileName)
        let updatedAt = Date()
        try ensureOwnRow(me)
        try userRepository.applyProfile(
            ownerUserId: me, userId: me,
            displayName: authService.currentUsername,
            avatarFileName: fileName,
            updatedAt: updatedAt
        )
        imageCache[fileName] = nil
        version += 1

        let key = AESGCM.randomKey()
        let sealed = try AESGCM.seal(plaintext: jpeg, key: key)
        let upload = try await apiClient.uploadMedia(data: sealed)

        savePublished(Published(
            avatarMediaId: upload.mediaId,
            avatarKey: key.withUnsafeBytes { Data($0) },
            updatedAt: updatedAt
        ), for: me)
        await shareWithAllContacts()
    }

    func removeMyAvatar() async {
        guard let me = authService.currentUserId else { return }
        let updatedAt = Date()
        if let url = avatarURL(fileName: "\(me)_\(me).jpg") {
            try? FileManager.default.removeItem(at: url)
        }
        try? ensureOwnRow(me)
        try? userRepository.applyProfile(
            ownerUserId: me, userId: me,
            displayName: authService.currentUsername,
            avatarFileName: nil,
            updatedAt: updatedAt
        )
        imageCache.removeAll()
        version += 1

        savePublished(Published(avatarMediaId: nil, avatarKey: nil, updatedAt: updatedAt), for: me)
        await shareWithAllContacts()
    }

    // MARK: Sharing

    /// Sends the current profile to this conversation's peer if they don't have
    /// it yet. Cheap to call often — it's a no-op once they're up to date.
    func ensureShared(with conversation: Conversation) async {
        guard let me = authService.currentUserId,
              conversation.relationshipState.allowsSending,
              let peerId = conversation.otherParticipant(myUserId: me),
              let published = loadPublished(for: me) else { return }

        var sent = loadSentTo(for: me)
        let stamp = published.updatedAt.timeIntervalSince1970
        guard sent[peerId] != stamp, !inFlight.contains(peerId) else { return }

        inFlight.insert(peerId)
        defer { inFlight.remove(peerId) }

        let payload = ProfilePayload(
            displayName: authService.currentUsername,
            avatarMediaId: published.avatarMediaId,
            avatarKey: published.avatarKey,
            updatedAt: published.updatedAt
        )
        do {
            try await sendHandler?(payload, conversation)
            sent[peerId] = stamp
            saveSentTo(sent, for: me)
        } catch {
            logger.debug("Profile not delivered to \(peerId, privacy: .public); will retry later")
        }
    }

    func ensureShared(conversationId: String) async {
        guard let me = authService.currentUserId,
              let conversation = try? conversationRepository.fetch(id: conversationId, ownerUserId: me)
        else { return }
        await ensureShared(with: conversation)
    }

    private func shareWithAllContacts() async {
        guard let me = authService.currentUserId,
              let conversations = try? conversationRepository.fetchAllSortedByRecentActivity(ownerUserId: me)
        else { return }
        for conversation in conversations {
            await ensureShared(with: conversation)
        }
    }

    // MARK: Incoming

    func applyRemote(_ payload: ProfilePayload, senderId: String, ownerUserId: String) async {
        // Out-of-order pushes: cheap check before downloading anything.
        if let user = try? userRepository.fetch(ownerUserId: ownerUserId, id: senderId),
           let current = user.profileUpdatedAt, current >= payload.updatedAt {
            return
        }

        let fileName = "\(ownerUserId)_\(senderId).jpg"
        var storedFileName: String?

        if let mediaId = payload.avatarMediaId, let keyData = payload.avatarKey {
            do {
                let encrypted = try await apiClient.downloadMedia(mediaId: mediaId)
                let jpeg = try AESGCM.open(ciphertext: encrypted, key: SymmetricKey(data: keyData))
                guard jpeg.count <= Self.maxAvatarBytes, UIImage(data: jpeg) != nil else {
                    logger.error("Rejected an inbound avatar that wasn't a valid image")
                    return
                }
                try writeAvatar(jpeg, fileName: fileName)
                storedFileName = fileName
            } catch {
                logger.error("Couldn't fetch avatar for \(senderId, privacy: .public)")
                return
            }
        } else if let url = avatarURL(fileName: fileName) {
            try? FileManager.default.removeItem(at: url)
        }

        let changed = (try? userRepository.applyProfile(
            ownerUserId: ownerUserId,
            userId: senderId,
            displayName: payload.displayName,
            avatarFileName: storedFileName,
            updatedAt: payload.updatedAt
        )) ?? false

        if changed {
            imageCache[fileName] = nil
            version += 1
        }
    }

    // MARK: Account cleanup

    func deleteLocalData(ownerUserId: String) {
        if let dir = try? avatarDirectory(),
           let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for file in files where file.hasPrefix("\(ownerUserId)_") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
        }
        defaults.removeObject(forKey: publishedKey(ownerUserId))
        defaults.removeObject(forKey: sentToKey(ownerUserId))
        imageCache.removeAll()
        version += 1
    }

    // MARK: Files

    private func avatarDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("avatars", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }
        return dir
    }

    private func avatarURL(fileName: String) -> URL? {
        try? avatarDirectory().appendingPathComponent(fileName)
    }

    private func writeAvatar(_ data: Data, fileName: String) throws {
        let url = try avatarDirectory().appendingPathComponent(fileName)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The self row is normally created at registration; recreate it as a
    /// placeholder if it's somehow missing, so the avatar has somewhere to live.
    private func ensureOwnRow(_ me: String) throws {
        if (try userRepository.fetch(ownerUserId: me, id: me)) == nil {
            try userRepository.upsertContactPlaceholder(
                ownerUserId: me, userId: me, username: authService.currentUsername ?? String(me.prefix(8))
            )
        }
    }

    // MARK: Persistence of sharing state

    private func publishedKey(_ owner: String) -> String { "profile.published.\(owner)" }
    private func sentToKey(_ owner: String) -> String { "profile.sentTo.\(owner)" }

    private func loadPublished(for owner: String) -> Published? {
        guard let data = defaults.data(forKey: publishedKey(owner)) else { return nil }
        return try? JSONDecoder().decode(Published.self, from: data)
    }

    private func savePublished(_ value: Published, for owner: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: publishedKey(owner))
        // A new version: everyone needs it again.
        defaults.removeObject(forKey: sentToKey(owner))
    }

    private func loadSentTo(for owner: String) -> [String: Double] {
        (defaults.dictionary(forKey: sentToKey(owner)) as? [String: Double]) ?? [:]
    }

    private func saveSentTo(_ value: [String: Double], for owner: String) {
        defaults.set(value, forKey: sentToKey(owner))
    }

    // MARK: Image processing

    /// Decodes straight to the target size (memory tracks the output, not the
    /// source photo) and bakes in EXIF orientation.
    private static func downsample(_ data: Data, maxPixelSize: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

enum ProfileError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "That image couldn't be used as a profile picture."
        }
    }
}
