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
    /// FIX (shared notepad): the pad is per-account data like everything
    /// else here — omitting it would leave a deleted account's shopping
    /// lists and to-dos behind in the shared `note_pad_items` table forever,
    /// the exact class of oversight that `users` suffered from until pack 4
    /// added `userRepository` to this same service.
    private let notePadRepository: NotePadRepository

    init(
        cryptoService: CryptoService,
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        sessionRepository: SessionRepository,
        userRepository: UserRepository,
        mediaEncryptionService: MediaEncryptionService,
        notePadRepository: NotePadRepository
    ) {
        self.cryptoService = cryptoService
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.sessionRepository = sessionRepository
        self.userRepository = userRepository
        self.mediaEncryptionService = mediaEncryptionService
        self.notePadRepository = notePadRepository
    }

    /// Order matters: database rows are removed while the storage key is
    /// still available, then the Keychain namespace goes.
    func deleteAccount(userId: String) throws {
        try mediaEncryptionService.deleteAllMedia(ownerUserId: userId)
        try messageRepository.deleteAll(ownerUserId: userId)
        try notePadRepository.deleteAll(ownerUserId: userId)
        try conversationRepository.deleteAll(ownerUserId: userId)
        try sessionRepository.deleteAll(ownerUserId: userId)
        try userRepository.deleteAll(ownerUserId: userId)
        cryptoService.deleteAccount(userId: userId)
        SyncCursorStore().reset(for: userId)
    }
}
