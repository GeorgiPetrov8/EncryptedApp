import Foundation
import Combine
import GRDB
import os

/// Everything an account consists of, in portable form.
///
/// Message bodies are stored as plaintext *inside the encrypted archive* and
/// re-encrypted with the new device's storage key on import — the old storage
/// key never leaves the old device.
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

    var errorDescription: String? {
        switch self {
        case .accountAlreadyOnDevice(let username):
            return "\(username) is already set up on this device. Sign in normally instead."
        case .storageLocked:
            return "Unlock HyperChat first."
        case .noEmail:
            return "Add and verify a recovery email first."
        }
    }
}

/// Account recovery: recovery email, encrypted backups, and restoring on a new device.
///
/// Two independent ways back in, because each covers what the other can't:
///
/// | You have…                         | You get back                         |
/// |-----------------------------------|--------------------------------------|
/// | backup file + its password        | everything (keys, chats, history)    |
/// | email + server backup + password  | everything                           |
/// | email only                        | your username, with NEW keys; history|
/// |                                   | is gone and contacts see a warning   |
///
/// Email alone can't restore history because the server never had it — that
/// is the price of end-to-end encryption, and it's the same in Signal/WhatsApp.
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
    private let logger = Logger(subsystem: "com.HyperChat", category: "recovery")

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
        messagingService: MessagingService
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
    }

    // MARK: Recovery email (signed in)

    func refreshEmailStatus() async {
        emailStatus = try? await api.emailStatus()
    }

    func requestEmailCode(_ email: String) async throws {
        try await api.requestEmailCode(email.trimmingCharacters(in: .whitespacesAndNewlines))
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

    /// Writes an encrypted backup file and returns its URL, ready for the share sheet.
    func exportBackupFile(password: String) async throws -> URL {
        isBusy = true
        defer { isBusy = false }

        let archive = try await makeArchive(password: password)
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let name = "HyperChat-\(authService.currentUsername ?? "backup")-\(stamp).hcbackup"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try archive.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Uploads the same encrypted archive to the server, so it can be restored
    /// with email + password when the phone is gone.
    func uploadServerBackup(password: String) async throws {
        guard emailStatus?.verified == true else { throw RecoveryError.noEmail }
        isBusy = true
        defer { isBusy = false }

        let archive = try await makeArchive(password: password)
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

    /// Restores from a `.hcbackup` file the user picked.
    func restore(fromFile url: URL, password: String) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        try await restore(archive: data, password: password)
    }

    /// Email path, step 1: sends a code to the account's recovery email.
    /// The server answers the same way whether or not the account exists.
    func startEmailRecovery(username: String) async throws {
        try await api.startRecovery(username: username.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Email path, step 2: exchanges the code for a short-lived ticket.
    func verifyEmailRecovery(username: String, code: String) async throws -> RecoveryTicket {
        try await api.verifyRecovery(
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            code: code.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Email path, step 3a: full restore from the server backup.
    func restoreFromServerBackup(ticket: RecoveryTicket, password: String) async throws {
        let archive = try await api.downloadBackup(ticket: ticket.ticket)
        try await restore(archive: archive, password: password)
    }

    /// Email path, step 3b: no backup (or password forgotten). Keeps the
    /// username, creates new keys. History can't come back, and contacts will
    /// see that this account's security keys changed.
    func recoverWithNewKeys(ticket: RecoveryTicket) async throws {
        isBusy = true
        defer { isBusy = false }

        // A reinstall can leave old keys in the Keychain; they're superseded now.
        cryptoService.deleteAccount(userId: ticket.userId)
        let bundle = try cryptoService.generateIdentityAndBundle(userId: ticket.userId, username: ticket.username)
        do {
            let token = try await api.rebind(ticket: ticket.ticket, bundle: bundle)
            try authService.adoptRecoveredSession(token: token, username: ticket.username, bundle: bundle)
        } catch {
            cryptoService.deleteAccount(userId: ticket.userId)
            throw error
        }
    }

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

            // One transaction: either the whole history lands or none of it.
            try database.dbQueue.write { db in
                for user in snapshot.users { try user.save(db) }
                for conversation in snapshot.conversations { try conversation.save(db) }
                for message in messages { try message.save(db) }
                for item in snapshot.notePadItems { try item.save(db) }
                for alarm in snapshot.alarms { try alarm.save(db) }
            }
        } catch {
            cryptoService.deleteAccount(userId: snapshot.userId)
            throw error
        }

        // Signs the server's login challenge with the restored identity key.
        try await authService.login(username: snapshot.username)

        // Old ratchet sessions weren't restored (they'd be behind the peers).
        // Start fresh ones so contacts can reach this device right away.
        await messagingService.reestablishSessions()
        logger.info("Restored \(snapshot.messages.count, privacy: .public) messages from backup")
    }
}
