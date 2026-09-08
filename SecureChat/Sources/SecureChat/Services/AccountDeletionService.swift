import Foundation

/// FIX (Bug #10): the single, explicit path that destroys an account's data.
///
/// Before this existed, data was destroyed implicitly and silently — registering a
/// second account overwrote the shared `localStorageKey`, which made the first
/// account's entire history permanently undecryptable while leaving the rows on
/// disk looking intact.
@MainActor
final class AccountDeletionService {
    private let cryptoService: CryptoService
    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let sessionRepository: SessionRepository
    private let mediaEncryptionService: MediaEncryptionService

    init(
        cryptoService: CryptoService,
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        sessionRepository: SessionRepository,
        mediaEncryptionService: MediaEncryptionService
    ) {
        self.cryptoService = cryptoService
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.sessionRepository = sessionRepository
        self.mediaEncryptionService = mediaEncryptionService
    }

    /// Order matters: database rows are removed while the storage key is still
    /// available, then the Keychain namespace goes. Doing it the other way round
    /// would leave undeletable ciphertext behind.
    ///
    /// FIX (Bug #23): media blobs on disk are deleted too. The schema's
    /// `onDelete: .cascade` only removed the media *rows*, so the encrypted files
    /// survived account deletion entirely.
    func deleteAccount(userId: String) throws {
        try mediaEncryptionService.deleteAllMedia(ownerUserId: userId)
        try messageRepository.deleteAll(ownerUserId: userId)
        try conversationRepository.deleteAll(ownerUserId: userId)
        try sessionRepository.deleteAll(ownerUserId: userId)
        cryptoService.deleteAccount(userId: userId)
        SyncCursorStore().reset(for: userId)
    }
}
