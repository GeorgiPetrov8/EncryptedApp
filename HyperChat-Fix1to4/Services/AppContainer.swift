import Foundation
import Combine
import GRDB
import os

/// Hand-rolled dependency container. Created once at app launch and passed
/// down via the environment. Construction order matters and is commented.
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
    let alarmRepository: AlarmRepository

    let authService: AuthService
    let messagingService: MessagingService
    let mediaEncryptionService: MediaEncryptionService
    let notePadService: NotePadService
    let alarmService: AlarmService
    let appLockService: AppLockService
    let accountDeletionService: AccountDeletionService
    let tenorService: TenorService
    let appearanceStore: AppearanceStore
    let callService: CallService
    let invitationService: InvitationService

    // FIX (problems 2–4): these existed as types but were never constructed.
    let receiptService: ReceiptService
    let presenceService: PresenceService
    let profileService: ProfileService

    private let logger = Logger(subsystem: "com.HyperChat", category: "container")
    private var cancellables = Set<AnyCancellable>()

    private init(database: DatabaseManager) {
        self.database = database
        self.cryptoService = CryptoService()
        self.tenorService = TenorService()
        self.appearanceStore = AppearanceStore()

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

        self.invitationService = InvitationService(
            conversationRepository: conversationRepository,
            userRepository: userRepository,
            messageRepository: messageRepository,
            authService: authService,
            apiClient: apiClient
        )

        self.callService = CallService(
            authService: authService,
            userRepository: userRepository,
            conversationRepository: conversationRepository
        )

        self.mediaEncryptionService = MediaEncryptionService(
            cryptoService: cryptoService,
            mediaRepository: mediaRepository,
            apiClient: apiClient
        )

        self.notePadService = NotePadService(repository: notePadRepository, authService: authService)

        self.alarmService = AlarmService(
            repository: alarmRepository,
            scheduler: AlarmScheduler(),
            audio: AlarmAudioService(),
            authService: authService,
            userRepository: userRepository,
            conversationRepository: conversationRepository
        )

        self.receiptService = ReceiptService(messageRepository: messageRepository, authService: authService)

        self.presenceService = PresenceService(
            webSocketService: webSocketService,
            authService: authService,
            conversationRepository: conversationRepository
        )

        self.profileService = ProfileService(
            userRepository: userRepository,
            conversationRepository: conversationRepository,
            authService: authService,
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
            notePadService: notePadService,
            authService: authService
        )

        // MARK: Send handlers (services that transmit through MessagingService)

        notePadService.setSendHandler { [weak messagingService] operation, conversation in
            try await messagingService?.sendNotePadOperation(operation, in: conversation)
        }

        alarmService.setSendMessageHandler { [weak messagingService] word, conversation in
            try await messagingService?.sendText(word, in: conversation)
        }

        receiptService.setSendHandler { [weak messagingService] payload, conversation in
            try await messagingService?.sendControlPayload(payload, kind: .receipt, in: conversation)
        }

        profileService.setSendHandler { [weak messagingService] payload, conversation in
            try await messagingService?.sendControlPayload(
                payload, kind: .profile, in: conversation, createdAt: payload.updatedAt
            )
        }

        // MARK: Receive routing (control messages arriving in MessagingService)

        let receiptService = self.receiptService
        let profileService = self.profileService
        messagingService.setControlHandlers(
            delivery: { [weak receiptService] message, conversation in
                receiptService?.acknowledgeDelivery(messageId: message.id, in: conversation)
            },
            receipt: { [weak receiptService] payload, conversation in
                receiptService?.applyRemote(
                    payload,
                    conversationId: conversation.id,
                    ownerUserId: conversation.ownerUserId
                )
            },
            profile: { [weak profileService] payload, conversation, senderId in
                Task {
                    await profileService?.applyRemote(
                        payload, senderId: senderId, ownerUserId: conversation.ownerUserId
                    )
                }
            }
        )

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

        // MARK: Change forwarding
        //
        // `@EnvironmentObject` only reacts to the object it references directly,
        // not to nested ObservableObjects.
        authService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        messagingService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        appLockService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        notePadService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        alarmService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        appearanceStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        receiptService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        presenceService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        profileService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        // A message from someone new may mean a new contact: refresh the
        // presence contact list and make sure they have our profile.
        messagingService.$incomingMessage
            .compactMap { $0?.conversationId }
            .sink { [weak self] conversationId in
                guard let self else { return }
                self.presenceService.refreshContacts()
                Task { await self.profileService.ensureShared(conversationId: conversationId) }
            }
            .store(in: &cancellables)

        authService.setLogoutHandler { [weak self] departingUserId in
            self?.messagingService.stopListening()
            self?.presenceService.stop()
            self?.mediaEncryptionService.clearCache(ownerUserId: departingUserId)
            self?.notePadService.clearInMemoryState()
            self?.alarmService.stopForLogout()
        }

        authService.$currentUserId
            .removeDuplicates()
            .sink { [weak self] userId in
                guard let self else { return }
                if userId != nil {
                    self.logger.debug("Active account changed; starting listener")
                    // Presence first: its stream must exist before the socket
                    // connects, or the post-auth snapshot is dropped.
                    self.presenceService.start()
                    self.messagingService.startListening()
                    Task { await self.alarmService.activate() }
                } else {
                    self.presenceService.stop()
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
