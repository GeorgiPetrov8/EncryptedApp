import Foundation
import Combine
import GRDB

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
    /// FIX (Bug #10): the single explicit path that destroys account data.
    let accountDeletionService: AccountDeletionService

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
        self.messagingService = MessagingService(
            cryptoService: cryptoService,
            apiClient: apiClient,
            webSocketService: webSocketService,
            conversationRepository: conversationRepository,
            messageRepository: messageRepository,
            sessionRepository: sessionRepository,
            userRepository: userRepository,
            authService: authService
        )
        self.mediaEncryptionService = MediaEncryptionService(
            cryptoService: cryptoService,
            mediaRepository: mediaRepository,
            apiClient: apiClient
        )
        self.appLockService = AppLockService()
        self.accountDeletionService = AccountDeletionService(
            cryptoService: cryptoService,
            conversationRepository: conversationRepository,
            messageRepository: messageRepository,
            sessionRepository: sessionRepository
        )

        // SwiftUI's @EnvironmentObject only reacts to the objectWillChange of the
        // object referenced directly by the property wrapper — not to nested
        // ObservableObjects inside it. Forwarding these means every view can observe
        // `container` and still react to service changes.
        authService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        messagingService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        appLockService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        if authService.isAuthenticated {
            messagingService.startListening()
        }
    }

    static func bootstrap() -> AppContainer {
        do {
            let database = try DatabaseManager()
            return AppContainer(database: database)
        } catch {
            // A failure here means the local encrypted store couldn't be created or
            // opened at all — there's no safe degraded mode for an E2EE messenger.
            fatalError("Failed to initialize SecureChat's local database: \(error)")
        }
    }
}
