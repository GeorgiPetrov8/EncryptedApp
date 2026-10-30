import Foundation
import Combine
import GRDB
import os

struct BackupSnapshot: Codable {
    struct BackupMessage: Codable {
        let id: String
        let conversationId: String
        let senderId: String
        let plaintext: Data
        let contentType: MessageContentType
        let deliveryStatus: DeliveryStatus
        let createdAt: Date
        let deliveredAt: Date?
        let readAt: Date?
        let editedAt: Date?
    }

    var format = 1
    let exportedAt: Date
    let userId: String
    let username: String
    let keys: ExportedKeyMaterial
    let users: [User]
    let conversations: [Conversation]
    let messages: [BackupMessage]
    let notePadItems: [NotePadItem]
    let alarms: [Alarm]
}

enum RecoveryError: LocalizedError {
    case accountAlreadyOnDevice(String)
    case storageLocked
    case noEmail
    case backupTooLarge
    case noMedia

    var errorDescription: String? {
        switch self {
        case .accountAlreadyOnDevice(let username):
            return "\(username) is already set up on this device. Sign in normally instead."
        case .storageLocked:
            return "Unlock SecureHyperChat first."
        case .noEmail:
            return "Add and verify a recovery email first."
        case .backupTooLarge:
            return "Your history is too large for a server backup (95 MB). Export a backup file instead."
        case .noMedia:
            return "There are no photos, videos or files on this phone to back up."
        }
    }
}

/// Account recovery: recovery email, encrypted backups, restoring on a new device.
///
/// NEW (R4): media backup. `exportMediaBackupFile()` writes every attachment on
/// this phone to a `.hcmedia` file (see `MediaBackupFile`); after restoring the
/// main backup on a new phone, `importMediaBackupFile(from:)` puts them back.
/// Restore also recreates the media rows, so the restored attachments behave
/// like ones that were received on this phone.
@MainActor
final class RecoveryService: ObservableObject {

    @Published private(set) var emailStatus: RecoveryEmailStatus?
    @Published private(set) var isBusy = false
    /// Progress of a media export / import: (done, total).
    @Published private(set) var mediaProgress: (done: Int, total: Int)?

    private let api: RecoveryAPI
    private let database: DatabaseManager
    private let cryptoService: CryptoService
    private let authService: AuthService
    private let userRepository: UserRepository
    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let notePadRepository: NotePadRepository
    private let alarmRepository: AlarmRepository
    private let messagingService: MessagingService
    private let mediaCache = MediaCacheStore()
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "recovery")
    private let proveChallenge: ChallengeSigner

    /// Cloudflare's free plan stops requests around 100 MB.
    static let maxServerBackupBytes = 95 * 1024 * 1024

    init(
        api: RecoveryAPI,
        database: DatabaseManager,
        cryptoService: CryptoService,
        authService: AuthService,
        userRepository: UserRepository,
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        notePadRepository: NotePadRepository,
        alarmRepository: AlarmRepository,
        messagingService: MessagingService,
        proveChallenge: @escaping ChallengeSigner
    ) {
        self.api = api
        self.database = database
        self.cryptoService = cryptoService
        self.authService = authService
        self.userRepository = userRepository
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.notePadRepository = notePadRepository
        self.alarmRepository = alarmRepository
        self.messagingService = messagingService
        self.proveChallenge = proveChallenge
    }

    // MARK: Recovery email (signed in)

    func refreshEmailStatus() async {
        emailStatus = try? await api.emailStatus()
    }

    func requestEmailCode(_ email: String) async throws {
        try await api.requestEmailCode(email.trimmingCharacters(in: .whitespacesAndNewlines), prove: proveChallenge)
        await refreshEmailStatus()
    }

    func verifyEmail(code: String) async throws {
        try await api.verifyEmail(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
        await refreshEmailStatus()
    }

    func removeEmail() async throws {
        try await api.removeEmail(prove: proveChallenge)
        await refreshEmailStatus()
    }

    /// Stops a recovery someone started on another device (server S2).
    func cancelRecovery() async throws {
        try await api.cancelRecovery()
        await refreshEmailStatus()
    }

    // MARK: Main backup (signed in)

    func exportBackupFile(password: String) async throws -> URL {
        isBusy = true
        defer { isBusy = false }

        let archive = try await makeArchive(password: password)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileStem()).hcbackup")
        try archive.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func uploadServerBackup(password: String) async throws {
        guard emailStatus?.verified == true else { throw RecoveryError.noEmail }
        isBusy = true
        defer { isBusy = false }

        let archive = try await makeArchive(password: password)
        guard archive.count <= Self.maxServerBackupBytes else { throw RecoveryError.backupTooLarge }
        try await api.uploadBackup(archive)
        await refreshEmailStatus()
    }

    func deleteServerBackup() async throws {
        try await api.deleteBackup(prove: proveChallenge)
        await refreshEmailStatus()
    }

    private func fileStem() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let user = (authService.currentUsername ?? "backup")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
        return "SecureHyperChat-\(user)-\(stamp)"
    }

    private func makeArchive(password: String) async throws -> Data {
        try BackupArchive.validate(password)
        guard authService.isStorageUnlocked else { throw RecoveryError.storageLocked }
        let snapshot = try buildSnapshot()
        let json = try JSONEncoder().encode(snapshot)
        return try await BackupArchive.seal(json, password: password)
    }

    private func buildSnapshot() throws -> BackupSnapshot {
        guard let me = authService.currentUserId, let username = authService.currentUsername else {
            throw APIError.notAuthenticated
        }
        let conversations = try conversationRepository.fetchAllSortedByRecentActivity(ownerUserId: me)

        var messages: [BackupSnapshot.BackupMessage] = []
        var notes: [NotePadItem] = []
        for conversation in conversations {
            for message in try messageRepository.fetchMessages(conversationId: conversation.id, ownerUserId: me) {
                let plaintext = message.isUndecryptable
                    ? Data()
                    : (try? cryptoService.decryptFromStorage(message.encryptedContent)) ?? Data()
                messages.append(.init(
                    id: message.id,
                    conversationId: message.conversationId,
                    senderId: message.senderId,
                    plaintext: plaintext,
                    contentType: message.contentType,
                    deliveryStatus: message.deliveryStatus,
                    createdAt: message.createdAt,
                    deliveredAt: message.deliveredAt,
                    readAt: message.readAt,
                    editedAt: message.editedAt
                ))
            }
            notes += try notePadRepository.fetchAll(ownerUserId: me, conversationId: conversation.id)
        }

        return BackupSnapshot(
            exportedAt: Date(),
            userId: me,
            username: username,
            keys: try cryptoService.exportKeyMaterial(),
            users: try userRepository.fetchAll(ownerUserId: me),
            conversations: conversations,
            messages: messages,
            notePadItems: notes,
            alarms: try alarmRepository.fetchAll(ownerUserId: me)
        )
    }

    // MARK: Media backup (R4)

    /// Writes every attachment on this phone to a `.hcmedia` file, one at a time.
    /// Attachments that were never opened (not downloaded yet) are fetched from the
    /// server first if it still has them.
    func exportMediaBackupFile() async throws -> URL {
        guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
        guard authService.isStorageUnlocked else { throw RecoveryError.storageLocked }
        isBusy = true
        defer {
            isBusy = false
            mediaProgress = nil
        }

        var mediaIds: [String] = []
        var seen = Set<String>()
        for message in try messageRepository.fetchMediaMessages(ownerUserId: me) where !message.isUndecryptable {
            guard let payloadData = try? cryptoService.decryptFromStorage(message.encryptedContent),
                  let payload = try? MediaEncryptionService.decodeValidated(payloadData) else { continue }
            let id = payload.mediaId.lowercased()
            if seen.insert(id).inserted {
                if !mediaCache.contains(mediaId: id) {
                    // Downloads into the cache if the server still has it.
                    _ = try? await messagingService.mediaData(for: message)
                }
                if mediaCache.contains(mediaId: id) { mediaIds.append(id) }
            }
        }
        guard !mediaIds.isEmpty else { throw RecoveryError.noMedia }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileStem()).hcmedia")
        try? FileManager.default.removeItem(at: url)
        let writer = try MediaBackupFile.Writer(url: url, userId: me)
        do {
            for (index, id) in mediaIds.enumerated() {
                mediaProgress = (index, mediaIds.count)
                try autoreleasepool {
                    try writer.add(mediaId: id, encrypted: try mediaCache.read(mediaId: id))
                }
                await Task.yield()
            }
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        logger.info("Media backup: \(writer.count, privacy: .public) attachments")
        return url
    }

    /// Restores attachments from a `.hcmedia` file into this phone's cache.
    /// Run after the main backup was restored (same account). Returns how many
    /// attachments were added.
    @discardableResult
    func importMediaBackupFile(from url: URL) async throws -> Int {
        guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
        isBusy = true
        defer {
            isBusy = false
            mediaProgress = nil
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let cache = mediaCache
        let added = try await Task.detached(priority: .userInitiated) { () throws -> Int in
            var added = 0
            try MediaBackupFile.read(url: url, expectedUserId: me) { mediaId, encrypted in
                guard !cache.contains(mediaId: mediaId) else { return }
                try cache.write(encrypted, mediaId: mediaId)
                added += 1
            }
            return added
        }.value
        logger.info("Media restore: \(added, privacy: .public) attachments added")
        return added
    }

    // MARK: Restore (signed out, new device)

    func restore(fromFile url: URL, password: String) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        try await restore(archive: data, password: password)
    }

    func startEmailRecovery(username: String) async throws {
        try await api.startRecovery(username: username.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func verifyEmailRecovery(username: String, code: String) async throws -> RecoveryTicket {
        try await api.verifyRecovery(
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            code: code.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func restoreFromServerBackup(ticket: RecoveryTicket, password: String) async throws {
        let archive = try await api.downloadBackup(ticket: ticket.ticket)
        try await restore(archive: archive, password: password)
    }

    /// Keeps the username, creates new keys. Old key material is put back if the
    /// server refuses (R20) — including the new "recoveryPending" (423) answer.
    func recoverWithNewKeys(ticket: RecoveryTicket) async throws {
        isBusy = true
        defer { isBusy = false }

        var previous: ExportedKeyMaterial?
        if cryptoService.hasIdentity(forUserId: ticket.userId) {
            try? cryptoService.loadIdentityFromKeychain(userId: ticket.userId)
            previous = try? cryptoService.exportKeyMaterial()
        }

        let bundle = try cryptoService.generateIdentityAndBundle(
            userId: ticket.userId, username: ticket.username, force: true
        )
        do {
            let token = try await api.rebind(ticket: ticket.ticket, bundle: bundle)
            try authService.adoptRecoveredSession(token: token, username: ticket.username, bundle: bundle)
        } catch {
            cryptoService.deleteAccount(userId: ticket.userId)
            if let previous {
                try? cryptoService.importKeyMaterial(previous, userId: ticket.userId)
            }
            throw error
        }
    }

    /// Signs in first, then writes history; everything is undone on failure (R21).
    private func restore(archive: Data, password: String) async throws {
        isBusy = true
        defer { isBusy = false }

        let json = try await BackupArchive.open(archive, password: password)
        let snapshot = try JSONDecoder().decode(BackupSnapshot.self, from: json)

        guard !cryptoService.hasIdentity(forUserId: snapshot.userId) else {
            throw RecoveryError.accountAlreadyOnDevice(snapshot.username)
        }

        try cryptoService.importKeyMaterial(snapshot.keys, userId: snapshot.userId)

        do {
            try await authService.login(username: snapshot.username)
        } catch {
            cryptoService.deleteAccount(userId: snapshot.userId)
            throw error
        }

        do {
            var mediaRows: [MediaItem] = []
            let messages = try snapshot.messages.map { item -> Message in
                if item.contentType != .text, !item.plaintext.isEmpty,
                   let payload = try? MediaEncryptionService.decodeValidated(item.plaintext),
                   let path = try? mediaCache.url(forMediaId: payload.mediaId).path {
                    mediaRows.append(MediaItem(
                        id: payload.mediaId,
                        messageId: item.id,
                        ownerUserId: snapshot.userId,
                        encryptedFilePath: path,
                        encryptedThumbnail: nil,
                        fileSize: 0,
                        mediaType: payload.mediaType,
                        createdAt: item.createdAt
                    ))
                }
                return Message(
                    id: item.id,
                    ownerUserId: snapshot.userId,
                    conversationId: item.conversationId,
                    senderId: item.senderId,
                    encryptedContent: item.plaintext.isEmpty ? Data() : try cryptoService.encryptForStorage(item.plaintext),
                    contentType: item.contentType,
                    deliveryStatus: item.deliveryStatus,
                    createdAt: item.createdAt,
                    deliveredAt: item.deliveredAt,
                    readAt: item.readAt,
                    editedAt: item.editedAt
                )
            }
            try await database.dbQueue.write { db in
                for user in snapshot.users where user.ownerUserId == snapshot.userId { try user.save(db) }
                for conversation in snapshot.conversations where conversation.ownerUserId == snapshot.userId {
                    try conversation.save(db)
                }
                for message in messages { try message.save(db) }
                // Media rows point at the cache path; the files arrive with
                // `importMediaBackupFile` (or from the server if it still has them).
                for row in mediaRows { try row.save(db) }
                for item in snapshot.notePadItems { try item.save(db) }
                for alarm in snapshot.alarms { try alarm.save(db) }
            }
        } catch {
            authService.logout()
            cryptoService.deleteAccount(userId: snapshot.userId)
            throw error
        }

        await messagingService.reestablishSessions()
        logger.info("Restored \(snapshot.messages.count, privacy: .public) messages from backup")
    }
}
