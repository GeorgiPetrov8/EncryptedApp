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
    /// FIX (real backend): exposed so views/services needing the current
    /// bearer token (or a debug screen showing connection state) can reach
    /// it without threading it through every initializer by hand.
    let sessionTokenStore: SessionTokenStore

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

    private let logger = Logger(subsystem: "com.securechat", category: "container")
    private var cancellables = Set<AnyCancellable>()

    private init(database: DatabaseManager) {
        self.database = database
        self.cryptoService = CryptoService()

        // FIX (real backend): `SessionTokenStore` is constructed before
        // everything that needs it and before `AuthService` exists — see the
        // type's own doc comment for why the token has to live here rather
        // than on `AuthService` itself.
        let tokenStore = SessionTokenStore()
        self.sessionTokenStore = tokenStore

        // FIX (real backend): the only place Mock vs. Real is chosen.
        //
        // `NetworkConfiguration.useMockBackend` reads the `USE_MOCK_BACKEND`
        // Info.plist key, set per Xcode scheme in `project.yml` — flip it to
        // run against `SecureChatServer/` instead of the in-memory mock
        // without touching a single line of `MessagingService`,
        // `CryptoService`, or any view. That substitutability was the whole
        // point of `APIClientProtocol`/`WebSocketServiceProtocol` existing.
        if NetworkConfiguration.useMockBackend {
            self.apiClient = MockAPIClient(store: .shared)
            self.webSocketService = MockWebSocketService(store: .shared)
        } else {
            self.apiClient = RealAPIClient(tokenStore: tokenStore)
            self.webSocketService = RealWebSocketService(tokenStore: tokenStore)
        }

        self.userRepository = UserRepository(dbQueue: database.dbQueue)
        self.conversationRepository = ConversationRepository(dbQueue: database.dbQueue)
        self.messageRepository = MessageRepository(dbQueue: database.dbQueue)
        self.mediaRepository = MediaRepository(dbQueue: database.dbQueue)
        self.sessionRepository = SessionRepository(dbQueue: database.dbQueue)

        self.authService = AuthService(
            cryptoService: cryptoService,
            apiClient: apiClient,
            userRepository: userRepository,
            tokenStore: tokenStore
        )

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

        authService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        messagingService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        appLockService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        authService.setLogoutHandler { [weak self] departingUserId in
            self?.messagingService.stopListening()
            self?.mediaEncryptionService.clearCache(ownerUserId: departingUserId)
        }

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

        mediaEncryptionService.pruneCache()

        logger.info("Backend mode: \(NetworkConfiguration.useMockBackend ? "mock" : "real", privacy: .public), base URL: \(NetworkConfiguration.baseURL.absoluteString, privacy: .public)")
    }

    static func bootstrap() -> AppContainer {
        do {
            let database = try DatabaseManager()
            return AppContainer(database: database)
        } catch {
            fatalError("Failed to initialize SecureChat's local database: \(error)")
        }
    }
}
