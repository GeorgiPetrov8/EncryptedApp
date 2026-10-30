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
/// ratchet-encrypted `.profile` envelope.
@MainActor
final class ProfileService: ObservableObject {

    @Published private(set) var version = 0
    @Published private(set) var isUpdating = false

    private let userRepository: UserRepository
    private let conversationRepository: ConversationRepository
    private let authService: AuthService
    private let apiClient: APIClientProtocol
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "profile")

    private var sendHandler: ((ProfilePayload, Conversation) async throws -> Void)?
    private var imageCache: [String: Data] = [:]
    private var inFlight: Set<String> = []

    private static let avatarPixelSize: CGFloat = 512
    private static let maxAvatarBytes = 2 * 1024 * 1024

    private struct PublishedProfile: Codable {
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

        guard let jpeg = ImageSafety.downsampledJPEG(raw, maxPixelSize: Self.avatarPixelSize) else {
            throw ProfileError.invalidImage
        }

        let fileName = Self.fileName(owner: me, user: me)
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

        savePublished(PublishedProfile(
            avatarMediaId: upload.mediaId,
            avatarKey: key.withUnsafeBytes { Data($0) },
            updatedAt: updatedAt
        ), for: me)
        await shareWithAllContacts()
    }

    func removeMyAvatar() async {
        guard let me = authService.currentUserId else { return }
        let updatedAt = Date()
        if let url = avatarURL(fileName: Self.fileName(owner: me, user: me)) {
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

        savePublished(PublishedProfile(avatarMediaId: nil, avatarKey: nil, updatedAt: updatedAt), for: me)
        await shareWithAllContacts()
    }

    // MARK: Sharing

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
            logger.debug("Profile not delivered yet; will retry later")
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

    /// Applies a contact's profile.
    ///
    /// FIX (R22, S31, S1):
    ///   - the media id must be a UUID before it touches the network or disk;
    ///   - the image's declared pixel size is checked and the avatar is
    ///     **re-encoded at 512 px** before it's stored, so nothing the sender put in
    ///     the file reaches the views;
    ///   - the update time can't be in the future (it would lock out later
    ///     updates);
    ///   - the display name is cleaned; it is shown only as an unverified extra.
    func applyRemote(_ payload: ProfilePayload, senderId: String, ownerUserId: String) async {
        let updatedAt = min(payload.updatedAt, Date().addingTimeInterval(5 * 60))
        if let user = try? userRepository.fetch(ownerUserId: ownerUserId, id: senderId),
           let current = user.profileUpdatedAt, current >= updatedAt {
            return
        }

        let fileName = Self.fileName(owner: ownerUserId, user: senderId)
        var storedFileName: String?

        if let mediaId = payload.avatarMediaId, let keyData = payload.avatarKey {
            guard SafeIdentifier.isMediaId(mediaId), keyData.count == 32 else {
                logger.error("Rejected a profile with a malformed avatar reference")
                return
            }
            do {
                let encrypted = try await apiClient.downloadMedia(mediaId: mediaId)
                guard encrypted.count <= Self.maxAvatarBytes + 64 else { return }
                let raw = try AESGCM.open(ciphertext: encrypted, key: SymmetricKey(data: keyData))
                guard let jpeg = ImageSafety.downsampledJPEG(raw, maxPixelSize: Self.avatarPixelSize) else {
                    logger.error("Rejected an inbound avatar that wasn't a safe image")
                    return
                }
                try writeAvatar(jpeg, fileName: fileName)
                storedFileName = fileName
            } catch {
                logger.error("Couldn't fetch a contact's avatar")
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
            updatedAt: updatedAt
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

    /// On logout: drop decoded avatars from memory (files stay; S35).
    func clearMemory() {
        imageCache.removeAll()
        version += 1
    }

    // MARK: Files

    /// User ids are UUIDs from the server; anything else is reduced to safe
    /// characters so a file name can never contain a path separator.
    private static func fileName(owner: String, user: String) -> String {
        func safe(_ s: String) -> String { String(s.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(64)) }
        return "\(safe(owner))_\(safe(user)).jpg"
    }

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
            BackupExclusion.exclude(dir)
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

    private func loadPublished(for owner: String) -> PublishedProfile? {
        guard let data = defaults.data(forKey: publishedKey(owner)) else { return nil }
        return try? JSONDecoder().decode(PublishedProfile.self, from: data)
    }

    private func savePublished(_ value: PublishedProfile, for owner: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: publishedKey(owner))
        defaults.removeObject(forKey: sentToKey(owner))
    }

    private func loadSentTo(for owner: String) -> [String: Double] {
        (defaults.dictionary(forKey: sentToKey(owner)) as? [String: Double]) ?? [:]
    }

    private func saveSentTo(_ value: [String: Double], for owner: String) {
        defaults.set(value, forKey: sentToKey(owner))
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
