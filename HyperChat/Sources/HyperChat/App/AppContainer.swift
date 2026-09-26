import Foundation
import Combine
import GRDB
import os

/// Simple hand-rolled dependency container (no DI framework needed at this
/// scale). Created once at app launch and passed down via the environment.
///
/// This is the merge point of everything layered on so far: the
/// real-backend networking switch, the media pipeline, the shared notepad,
/// and now alarms. Construction order matters in several places and is
/// commented where it does.
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
    let notePadRepository: NotePadRepository
    /// FIX (alarm)
    let alarmRepository: AlarmRepository

    let authService: AuthService
    let messagingService: MessagingService
    let mediaEncryptionService: MediaEncryptionService
    let notePadService: NotePadService
    /// FIX (alarm)
    let alarmService: AlarmService
    let appLockService: AppLockService
    let accountDeletionService: AccountDeletionService

    private let logger = Logger(subsystem: "com.HyperChat", category: "container")
    private var cancellables = Set<AnyCancellable>()

    private init(database: DatabaseManager) {
        self.database = database
        self.cryptoService = CryptoService()

        let tokenStore = SessionTokenStore()
        self.sessionTokenStore = tokenStore

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
        self.notePadRepository = NotePadRepository(dbQueue: database.dbQueue)
        self.alarmRepository = AlarmRepository(dbQueue: database.dbQueue)

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

        self.notePadService = NotePadService(repository: notePadRepository, authService: authService)

        // FIX (alarm): built before `messagingService`, which is fine —
        // unlike the notepad, `MessagingService` has no need to *route* to
        // the alarm service, so this is a one-way dependency resolved by
        // `setSendMessageHandler` below rather than a mutual one.
        self.alarmService = AlarmService(
            repository: alarmRepository,
            scheduler: AlarmScheduler(),
            audio: AlarmAudioService(),
            authService: authService,
            userRepository: userRepository,
            conversationRepository: conversationRepository
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
            notePadService: notePadService,
            authService: authService
        )

        notePadService.setSendHandler { [weak messagingService] operation, conversation in
            try await messagingService?.sendNotePadOperation(operation, in: conversation)
        }

        // FIX (alarm): the accountability word goes out as an ordinary
        // end-to-end encrypted text message — no special envelope type, no
        // separate code path. The recipient sees it in the chat exactly as
        // if it had been typed by hand, which is the point: the proof of
        // being awake has to be visible to a person, not just to the app.
        //
        // `[weak messagingService]` for the same reason as the notepad
        // handler above — closures held by a service that the messaging
        // service itself may reference would otherwise form a cycle.
        alarmService.setSendMessageHandler { [weak messagingService] word, conversation in
            try await messagingService?.sendText(word, in: conversation)
        }

        self.appLockService = AppLockService()
        self.accountDeletionService = AccountDeletionService(
            cryptoService: cryptoService,
            conversationRepository: conversationRepository,
            messageRepository: messageRepository,
            sessionRepository: sessionRepository,
            userRepository: userRepository,
            mediaEncryptionService: mediaEncryptionService,
            notePadRepository: notePadRepository,
            alarmRepository: alarmRepository
        )

        // SwiftUI's @EnvironmentObject only reacts to the objectWillChange
        // of the object referenced directly by the property wrapper — not
        // to nested ObservableObjects inside it.
        authService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        messagingService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        appLockService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        notePadService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        // FIX (alarm): without this, `RootView`'s overlay wouldn't appear
        // when an alarm starts ringing — it observes `container`, not
        // `alarmService` directly.
        alarmService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        authService.setLogoutHandler { [weak self] departingUserId in
            self?.messagingService.stopListening()
            self?.mediaEncryptionService.clearCache(ownerUserId: departingUserId)
            self?.notePadService.clearInMemoryState()
            // FIX (alarm): cancels scheduled notifications and silences any
            // alarm currently ringing. Leaving them scheduled would mean a
            // signed-out device ringing for an account that isn't there —
            // and, worse, an unsilenceable one, since the message-mode
            // challenge needs an active session to send anything.
            self?.alarmService.stopForLogout()
        }

        authService.$currentUserId
            .removeDuplicates()
            .sink { [weak self] userId in
                guard let self else { return }
                if userId != nil {
                    self.logger.debug("Active account changed; starting listener")
                    self.messagingService.startListening()
                    Task { await self.alarmService.activate() }
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
            fatalError("Failed to initialize HyperChat's local database: \(error)")
        }
    }
}
