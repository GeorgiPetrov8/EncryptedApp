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

        // The alarm word is an ordinary chat message — but only to someone who
        // accepted. Otherwise it would be silently queued and the alarm would
        // stop as if the message had been delivered; throwing makes the alarm
        // fall back to the arithmetic challenge instead.
        alarmService.setSendMessageHandler { [weak messagingService] word, conversation in
            guard let messagingService else { return }
            guard messagingService.relationshipState(of: conversation) == .accepted else {
                throw InvitationError.notAccepted
            }
            try await messagingService.sendText(word, in: conversation)
        }

        receiptService.setSendHandler { [weak messagingService] payload, conversation in
            try await messagingService?.sendControlPayload(payload, kind: .receipt, in: conversation)
        }

        profileService.setSendHandler { [weak messagingService] payload, conversation in
            try await messagingService?.sendControlPayload(
                payload, kind: .profile, in: conversation, createdAt: payload.updatedAt
            )
        }

        // FIX (problem 5): invitations were never connected to the transport.
        invitationService.setSendHandler { [weak messagingService] payload, conversation in
            try await messagingService?.sendControlPayload(payload, kind: .invite, in: conversation)
        }
        invitationService.setFlushHandler { [weak messagingService] conversation in
            await messagingService?.flushQueuedMessages(in: conversation)
        }

        // FIX (calls): call signalling was never connected either.
        callService.setSendHandler { [weak messagingService] signal, conversation in
            try await messagingService?.sendControlPayload(signal, kind: .call, in: conversation)
        }

        // MARK: Receive routing

        let receiptService = self.receiptService
        let profileService = self.profileService
        let invitationService = self.invitationService
        let callService = self.callService
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
            },
            invite: { [weak invitationService] payload, conversation, senderId in
                invitationService?.applyRemote(
                    payload,
                    conversation: conversation,
                    senderId: senderId,
                    ownerUserId: conversation.ownerUserId
                )
            },
            call: { [weak callService] signal, conversation, senderId in
                Task { await callService?.handle(signal, from: senderId, conversation: conversation) }
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
        // `@EnvironmentObject` only reacts to the object it references directly.
        // FIX: invitations, calls and Tenor weren't forwarded, so the
        // Invitations list didn't update after accepting, the call screen never
        // appeared, and GIF search results didn't render.
        let forwarded: [AnyPublisher<Void, Never>] = [
            authService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            messagingService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            appLockService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            notePadService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            alarmService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            appearanceStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            receiptService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            presenceService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            profileService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            invitationService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            callService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            tenorService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(forwarded)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // A message from someone new may be a message request; refresh the
        // Invitations list, presence contacts and profile sharing.
        messagingService.$incomingMessage
            .compactMap { $0?.conversationId }
            .sink { [weak self] conversationId in
                guard let self else { return }
                self.invitationService.reloadPending()
                self.presenceService.refreshContacts()
                Task { await self.profileService.ensureShared(conversationId: conversationId) }
            }
            .store(in: &cancellables)

        // An invitation accepted (either way) makes a new contact: start
        // showing presence and send them our profile photo.
        invitationService.changes
            .sink { [weak self] conversationId in
                guard let self else { return }
                self.presenceService.refreshContacts()
                Task { await self.profileService.ensureShared(conversationId: conversationId) }
            }
            .store(in: &cancellables)

        authService.setLogoutHandler { [weak self] departingUserId in
            guard let self else { return }
            Task { await self.callService.hangUp() }
            self.messagingService.stopListening()
            self.presenceService.stop()
            self.mediaEncryptionService.clearCache(ownerUserId: departingUserId)
            self.notePadService.clearInMemoryState()
            self.alarmService.stopForLogout()
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
                    self.invitationService.reloadPending()
                    Task { await self.alarmService.activate() }
                } else {
                    self.presenceService.stop()
                    self.messagingService.stopListening()
                    self.invitationService.reloadPending()
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
