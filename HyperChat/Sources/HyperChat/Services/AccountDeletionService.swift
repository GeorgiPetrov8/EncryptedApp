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

    init(
        cryptoService: CryptoService,
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        sessionRepository: SessionRepository,
        userRepository: UserRepository,
        mediaEncryptionService: MediaEncryptionService
    ) {
        self.cryptoService = cryptoService
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.sessionRepository = sessionRepository
        self.userRepository = userRepository
        self.mediaEncryptionService = mediaEncryptionService
    }

    /// Order matters: database rows are removed while the storage key is still
    /// available, then the Keychain namespace goes. Doing it the other way round
    /// would leave undeletable ciphertext behind.
    func deleteAccount(userId: String) throws {
        try mediaEncryptionService.deleteAllMedia(ownerUserId: userId)
        try messageRepository.deleteAll(ownerUserId: userId)
        try conversationRepository.deleteAll(ownerUserId: userId)
        try sessionRepository.deleteAll(ownerUserId: userId)

        // FIX: the contacts this account pinned.
        //
        // Previously omitted, so deleting an account left its pinned identity keys,
        // usernames and verification flags in the shared `users` table indefinitely —
        // a record of who the user had talked to, surviving an operation whose whole
        // purpose is to remove exactly that. It was not even expressible before
        // `users` gained `ownerUserId`, which is why it was missed.
        try userRepository.deleteAll(ownerUserId: userId)

        cryptoService.deleteAccount(userId: userId)
        SyncCursorStore().reset(for: userId)
    }
}
