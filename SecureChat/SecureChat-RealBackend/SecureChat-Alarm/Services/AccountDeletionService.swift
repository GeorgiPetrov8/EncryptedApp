import Foundation

/// The single, explicit path that destroys an account's data (Bug #10).
@MainActor
final class AccountDeletionService {
    private let cryptoService: CryptoService
    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let sessionRepository: SessionRepository
    private let userRepository: UserRepository
    private let mediaEncryptionService: MediaEncryptionService
    private let notePadRepository: NotePadRepository
    /// FIX (alarm): alarms are per-account data like everything else here.
    ///
    /// Omitting this would leave a deleted account's wake-up times — and,
    /// in `.messageContact` mode, the id of the person they'd arranged to
    /// message every morning — sitting in the shared `alarms` table
    /// indefinitely. That's the same class of oversight `users` had until
    /// it was added to this service, and it's arguably more sensitive:
    /// alarm times describe someone's daily routine.
    private let alarmRepository: AlarmRepository

    init(
        cryptoService: CryptoService,
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        sessionRepository: SessionRepository,
        userRepository: UserRepository,
        mediaEncryptionService: MediaEncryptionService,
        notePadRepository: NotePadRepository,
        alarmRepository: AlarmRepository
    ) {
        self.cryptoService = cryptoService
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.sessionRepository = sessionRepository
        self.userRepository = userRepository
        self.mediaEncryptionService = mediaEncryptionService
        self.notePadRepository = notePadRepository
        self.alarmRepository = alarmRepository
    }

    /// Order matters: database rows are removed while the storage key is
    /// still available, then the Keychain namespace goes.
    func deleteAccount(userId: String) throws {
        try mediaEncryptionService.deleteAllMedia(ownerUserId: userId)
        try messageRepository.deleteAll(ownerUserId: userId)
        try notePadRepository.deleteAll(ownerUserId: userId)
        try alarmRepository.deleteAll(ownerUserId: userId)
        try conversationRepository.deleteAll(ownerUserId: userId)
        try sessionRepository.deleteAll(ownerUserId: userId)
        try userRepository.deleteAll(ownerUserId: userId)
        cryptoService.deleteAccount(userId: userId)
        SyncCursorStore().reset(for: userId)
    }
}
