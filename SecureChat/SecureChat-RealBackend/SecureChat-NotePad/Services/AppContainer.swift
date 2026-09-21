import Foundation
import Combine
import GRDB
import os

/// Simple hand-rolled dependency container (no DI framework needed at this
/// scale). Created once at app launch and passed down via the environment.
///
/// This is the merge point of three additions layered on top of each other
/// across this project's history: the real-backend networking switch
/// (`sessionTokenStore`, `NetworkConfiguration.useMockBackend`), the media
/// pipeline (`mediaEncryptionService` built before `messagingService`,
/// because the latter now depends on the former), and the shared notepad
/// (`notePadRepository`/`notePadService`, wired the same way media was).
@MainActor
final class AppContainer: ObservableObject {
    let database: DatabaseManager
    let cryptoService: CryptoService
    let apiClient: APIClientProtocol
    let webSocketService: WebSocketServiceProtocol
    let sessionTokenStore: SessionTokenStore

    let userRepository: UserRepository
    let conversationRepository: ConversationRepository
    let messageRepository: MessageRepository
    let mediaRepository: MediaRepository
    let sessionRepository: SessionRepository
    /// FIX (shared notepad)
    let notePadRepository: NotePadRepository

    let authService: AuthService
    let messagingService: MessagingService
    let mediaEncryptionService: MediaEncryptionService
    /// FIX (shared notepad)
    let notePadService: NotePadService
    let appLockService: AppLockService
    let accountDeletionService: AccountDeletionService

    private let logger = Logger(subsystem: "com.securechat", category: "container")
    private var cancellables = Set<AnyCancellable>()

    private init(database: DatabaseManager) {
        self.database = database
        self.cryptoService = CryptoService()

        // `SessionTokenStore` is constructed before everything that needs
        // it, and before `AuthService` exists — see the type's own doc
        // comment for why the token has to live independently of
        // `AuthService` rather than on it.
        let tokenStore = SessionTokenStore()
        self.sessionTokenStore = tokenStore

        // The only place Mock vs. Real backend is chosen — flip
        // `USE_MOCK_BACKEND` per scheme in project.yml without touching
        // `MessagingService`, `CryptoService`, or any view.
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
        // FIX (shared notepad)
        self.notePadRepository = NotePadRepository(dbQueue: database.dbQueue)

        self.authService = AuthService(
            cryptoService: cryptoService,
            apiClient: apiClient,
            userRepository: userRepository,
            tokenStore: tokenStore
        )

        // Built before `messagingService`, which depends on it — the
        // receive path needs to create the recipient's `MediaItem`, and
        // there's no call site to thread a service into `handleIncoming`
        // (driven by a background stream, not a caller).
        self.mediaEncryptionService = MediaEncryptionService(
            cryptoService: cryptoService,
            mediaRepository: mediaRepository,
            apiClient: apiClient
        )

        // FIX (shared notepad): same ordering requirement as
        // `mediaEncryptionService` above, and for the identical reason —
        // `MessagingService.handleIncoming` routes `.notePad` envelopes to
        // this without a caller in the loop, so it must already exist by
        // the time `messagingService` is constructed.
        self.notePadService = NotePadService(repository: notePadRepository, authService: authService)

        self.messagingService = MessagingService(
            cryptoService: cryptoService,
            apiClient: apiClient,
            webSocketService: webSocketService,
            conversationRepository: conversationRepository,
            messageRepository: messageRepository,
            sessionRepository: sessionRepository,
            userRepository: userRepository,
            mediaEncryptionService: mediaEncryptionService,
            notePadService: notePadService,
            authService: authService
        )

        // FIX (shared notepad): the other half of the construction-order
        // cycle `NotePadService.setSendHandler`'s doc comment describes —
        // now that `messagingService` exists, hand it the closure that
        // actually transmits an operation. `[weak messagingService]`
        // matters here specifically because `messagingService` in turn
        // holds `notePadService`; without `weak` this closure would complete
        // a retain cycle between the two.
        notePadService.setSendHandler { [weak messagingService] operation, conversation in
            try await messagingService?.sendNotePadOperation(operation, in: conversation)
        }

        self.appLockService = AppLockService()
        self.accountDeletionService = AccountDeletionService(
            cryptoService: cryptoService,
            conversationRepository: conversationRepository,
            messageRepository: messageRepository,
            sessionRepository: sessionRepository,
            userRepository: userRepository,
            mediaEncryptionService: mediaEncryptionService,
            notePadRepository: notePadRepository
        )

        // SwiftUI's @EnvironmentObject only reacts to the objectWillChange
        // of the object referenced directly by the property wrapper — not
        // to nested ObservableObjects inside it.
        authService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        messagingService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        appLockService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        // FIX (shared notepad): forwarded for the same reason as the three
        // above — a view observing only `container` must still redraw when
        // `notePadService.itemsByConversation` changes.
        notePadService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        authService.setLogoutHandler { [weak self] departingUserId in
            self?.messagingService.stopListening()
            self?.mediaEncryptionService.clearCache(ownerUserId: departingUserId)
            // FIX (shared notepad): drops the in-memory pad cache so a
            // different account signing in next doesn't briefly see this
            // account's items before its own `loadItems` call runs. Does
            // not touch disk — logout never destroys data (Bug #10).
            self?.notePadService.clearInMemoryState()
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
