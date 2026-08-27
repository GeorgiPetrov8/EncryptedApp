import Foundation

/// FIX (Bug #10): the single, explicit path that destroys an account's data.
///
/// Before this existed, data was destroyed implicitly and silently — registering a
/// second account overwrote the shared `localStorageKey`, which made the first
/// account's entire history permanently undecryptable while leaving the rows on
/// disk looking intact.
///
/// Deletion is now the *only* destructive operation, it is deliberate, and it clears
/// both halves: the Keychain namespace and every owned row in the database.
@MainActor
final class AccountDeletionService {
    private let cryptoService: CryptoService
    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let sessionRepository: SessionRepository

    init(
        cryptoService: CryptoService,
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        sessionRepository: SessionRepository
    ) {
        self.cryptoService = cryptoService
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.sessionRepository = sessionRepository
    }

    /// Order matters: database rows are removed while the storage key is still
    /// available, then the Keychain namespace goes. Doing it the other way round
    /// would leave undeletable ciphertext behind.
    func deleteAccount(userId: String) throws {
        try messageRepository.deleteAll(ownerUserId: userId)
        try conversationRepository.deleteAll(ownerUserId: userId)
        try sessionRepository.deleteAll(ownerUserId: userId)
        cryptoService.deleteAccount(userId: userId)
    }
}
