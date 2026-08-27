import Foundation
import Combine
import GRDB
import os

/// Simple hand-rolled dependency container (no DI framework needed at this
/// scale). Created once at app launch and passed down via the environment.
@MainActor
final class AppContainer: ObservableObject {
    let database: DatabaseManager
    let cryptoService: CryptoService
    let apiClient: APIClientProtocol
    let webSocketService: WebSocketServiceProtocol

    let userRepository: UserRepository
    let conversationRepository: ConversationRepository
    let messageRepository: MessageRepository
    let mediaRepository: MediaRepository
    let sessionRepository: SessionRepository

    let authService: AuthService
    let messagingService: MessagingService
    let mediaEncryptionService: MediaEncryptionService
    let appLockService: AppLockService
    let accountDeletionService: AccountDeletionService

    private let logger = Logger(subsystem: "com.HyperChat", category: "container")
    private var cancellables = Set<AnyCancellable>()

    private init(database: DatabaseManager) {
        self.database = database
        self.cryptoService = CryptoService()
        self.apiClient = MockAPIClient(store: .shared)
        self.webSocketService = MockWebSocketService(store: .shared)

        self.userRepository = UserRepository(dbQueue: database.dbQueue)
        self.conversationRepository = ConversationRepository(dbQueue: database.dbQueue)
        self.messageRepository = MessageRepository(dbQueue: database.dbQueue)
        self.mediaRepository = MediaRepository(dbQueue: database.dbQueue)
        self.sessionRepository = SessionRepository(dbQueue: database.dbQueue)

        self.authService = AuthService(cryptoService: cryptoService, apiClient: apiClient, userRepository: userRepository)

        // FIX: built before `messagingService`, which now depends on it.
        //
        // The receive path needs to create the recipient's `MediaItem`, and there's no
        // way to thread a service into `handleIncoming` — it's driven by a background
        // stream, not by a caller. `MediaEncryptionService` depends only on the crypto
        // service, the media repository and the API client, none of which reach back
        // into messaging, so the ordering is the whole of the change.
        self.mediaEncryptionService = MediaEncryptionService(
            cryptoService: cryptoService,
            mediaRepository: mediaRepository,
            apiClient: apiClient
        )

        self.messagingService = MessagingService(
            cryptoService: cryptoService,
            apiClient: apiClient,
            webSocketService: webSocketService,
            conversationRepository: conversationRepository,
            messageRepository: messageRepository,
            sessionRepository: sessionRepository,
            userRepository: userRepository,
            mediaEncryptionService: mediaEncryptionService,
            authService: authService
        )

        self.appLockService = AppLockService()
        self.accountDeletionService = AccountDeletionService(
            cryptoService: cryptoService,
            conversationRepository: conversationRepository,
            messageRepository: messageRepository,
            sessionRepository: sessionRepository,
            userRepository: userRepository,
            mediaEncryptionService: mediaEncryptionService
        )

        // SwiftUI's @EnvironmentObject only reacts to the objectWillChange of the
        // object referenced directly by the property wrapper — not to nested
        // ObservableObjects inside it.
        authService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        messagingService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        appLockService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        // Evict only the departing account's cached media (Bug #23).
        authService.setLogoutHandler { [weak self] departingUserId in
            self?.messagingService.stopListening()
            self?.mediaEncryptionService.clearCache(ownerUserId: departingUserId)
        }

        // The listener follows the active account automatically (Bug #25).
        authService.$currentUserId
            .removeDuplicates()
            .sink { [weak self] userId in
                guard let self else { return }
                if userId != nil {
                    self.logger.debug("Active account changed; starting listener")
                    self.messagingService.startListening()
                } else {
                    self.messagingService.stopListening()
                }
            }
            .store(in: &cancellables)

        // Trim the media cache once per launch (Bug #23).
        mediaEncryptionService.pruneCache()
    }

    static func bootstrap() -> AppContainer {
        do {
            let database = try DatabaseManager()
            return AppContainer(database: database)
        } catch {
            // A failure here means the local encrypted store couldn't be created or
            // opened at all — there's no safe degraded mode for an E2EE messenger.
            fatalError("Failed to initialize HyperChat's local database: \(error)")
        }
    }
}
