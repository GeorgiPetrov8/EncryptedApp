import Foundation
import Combine
import GRDB
import os

/// Everything an account consists of, in portable form.
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

    var errorDescription: String? {
        switch self {
        case .accountAlreadyOnDevice(let username):
            return "\(username) is already set up on this device. Sign in normally instead."
        case .storageLocked:
            return "Unlock SecureHyperChat first."
        case .noEmail:
            return "Add and verify a recovery email first."
        case .backupTooLarge:
            return "Your history is too large for a server backup (50 MB). Export a backup file instead."
        }
    }
}

/// Account recovery: recovery email, encrypted backups, and restoring on a new device.
@MainActor
final class RecoveryService: ObservableObject {

    @Published private(set) var emailStatus: RecoveryEmailStatus?
    @Published private(set) var isBusy = false

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
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "recovery")
    private let proveChallenge: ChallengeSigner

    /// The server refuses backups over this size.
    static let maxServerBackupBytes = 50 * 1024 * 1024

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
        try await api.requestEmailCode(
            email.trimmingCharacters(in: .whitespacesAndNewlines),
            prove: proveChallenge
        )
        await refreshEmailStatus()
    }

    func verifyEmail(code: String) async throws {
        try await api.verifyEmail(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
        await refreshEmailStatus()
    }

    func removeEmail() async throws {
        try await api.removeEmail()
        await refreshEmailStatus()
    }

    // MARK: Export (signed in)

    func exportBackupFile(password: String) async throws -> URL {
        isBusy = true
        defer { isBusy = false }

        let archive = try await makeArchive(password: password)
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let user = (authService.currentUsername ?? "backup").filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SecureHyperChat-\(user)-\(stamp).hcbackup")
        try archive.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func uploadServerBackup(password: String) async throws {
        guard emailStatus?.verified == true else { throw RecoveryError.noEmail }
        isBusy = true
        defer { isBusy = false }

        let archive = try await makeArchive(password: password)
        // R24: say so plainly instead of a bare "413" from the server.
        guard archive.count <= Self.maxServerBackupBytes else { throw RecoveryError.backupTooLarge }
        try await api.uploadBackup(archive)
        await refreshEmailStatus()
    }

    func deleteServerBackup() async throws {
        try await api.deleteBackup()
        await refreshEmailStatus()
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

    /// Email path, step 3b: no backup (or password forgotten). Keeps the username,
    /// creates new keys.
    ///
    /// FIX (R20): the old keys used to be deleted *before* the server accepted the
    /// new ones. If `rebind` then failed (expired ticket, no network) the old
    /// identity was gone and the new one was thrown away too — nothing left. Now
    /// the old key material is kept in memory and put back if the server refuses.
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
                logger.info("Rebind failed; the previous keys were put back")
            }
            throw error
        }
    }

    /// FIX (R21): sign in **before** writing anything locally, and undo everything
    /// if any step fails.
    ///
    /// The old order was import keys → write history → sign in. If sign-in failed
    /// (offline, or the server already has newer keys after a recovery elsewhere)
    /// the keys stayed on the device: every later attempt said "already set up on
    /// this device — sign in normally", and signing in normally failed too. The
    /// user was stuck with no way forward.
    private func restore(archive: Data, password: String) async throws {
        isBusy = true
        defer { isBusy = false }

        let json = try await BackupArchive.open(archive, password: password)
        let snapshot = try JSONDecoder().decode(BackupSnapshot.self, from: json)

        guard !cryptoService.hasIdentity(forUserId: snapshot.userId) else {
            throw RecoveryError.accountAlreadyOnDevice(snapshot.username)
        }

        try cryptoService.importKeyMaterial(snapshot.keys, userId: snapshot.userId)

        // 1. Prove the keys still belong to this account on the server.
        do {
            try await authService.login(username: snapshot.username)
        } catch {
            cryptoService.deleteAccount(userId: snapshot.userId)
            throw error
        }

        // 2. Only now write the history.
        do {
            let messages = try snapshot.messages.map { item in
                Message(
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
