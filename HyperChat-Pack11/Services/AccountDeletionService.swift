import Foundation

enum AccountDeletionError: LocalizedError {
    case serverUnreachable(Error)

    var errorDescription: String? {
        switch self {
        case .serverUnreachable(let error):
            return "Couldn't delete the account on the server: \(error.localizedDescription)"
        }
    }
}

/// The single, explicit path that destroys an account's data.
@MainActor
final class AccountDeletionService {
    private let cryptoService: CryptoService
    private let apiClient: APIClientProtocol
    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let sessionRepository: SessionRepository
    private let userRepository: UserRepository
    private let mediaEncryptionService: MediaEncryptionService
    private let notePadRepository: NotePadRepository
    private let alarmRepository: AlarmRepository

    init(
        cryptoService: CryptoService,
        apiClient: APIClientProtocol,
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        sessionRepository: SessionRepository,
        userRepository: UserRepository,
        mediaEncryptionService: MediaEncryptionService,
        notePadRepository: NotePadRepository,
        alarmRepository: AlarmRepository
    ) {
        self.cryptoService = cryptoService
        self.apiClient = apiClient
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.sessionRepository = sessionRepository
        self.userRepository = userRepository
        self.mediaEncryptionService = mediaEncryptionService
        self.notePadRepository = notePadRepository
        self.alarmRepository = alarmRepository
    }

    /// Deletes the account on the server, then everything on this device.
    ///
    /// FIX: deletion used to be local only — the username, public keys,
    /// queued messages, recovery email and server backup all stayed on the
    /// server. The server step runs first because it needs the identity key
    /// to sign; if it fails, nothing local is touched and the error is
    /// thrown, so the user can retry or choose `includeServer: false`.
    func deleteAccount(userId: String, includeServer: Bool = true) async throws {
        if includeServer {
            do {
                try await apiClient.deleteAccountOnServer { [cryptoService] challenge in
                    try cryptoService.signChallenge(challenge, expectedUserId: userId)
                }
            } catch {
                throw AccountDeletionError.serverUnreachable(error)
            }
        }
        try deleteLocalData(userId: userId)
    }

    /// Order matters: database rows go while the storage key still exists,
    /// then the Keychain namespace.
    func deleteLocalData(userId: String) throws {
        try mediaEncryptionService.deleteAllMedia(ownerUserId: userId)
        try messageRepository.deleteAll(ownerUserId: userId)
        try notePadRepository.deleteAll(ownerUserId: userId)
        try alarmRepository.deleteAll(ownerUserId: userId)
        try conversationRepository.deleteAll(ownerUserId: userId)
        try sessionRepository.deleteAll(ownerUserId: userId)
        try userRepository.deleteAll(ownerUserId: userId)
        // FIX: retained handshakes and unsent pad edits used to survive deletion.
        PendingHandshakeStore().clearAll(ownerUserId: userId)
        UserDefaults.standard.removeObject(forKey: "notepad.pending.\(userId)")
        cryptoService.deleteAccount(userId: userId)
        SyncCursorStore().reset(for: userId)
    }
}
