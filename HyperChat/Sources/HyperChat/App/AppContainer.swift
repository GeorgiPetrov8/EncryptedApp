import Foundation
import Combine
import GRDB
import os

/// Hand-rolled dependency container. Created once at app launch.
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
    let recoveryService: RecoveryService
    /// NEW: APNs registration.
    let pushService: PushService
    let ntfyService: NtfyService

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

        self.pushService = PushService(apiClient: apiClient, authService: authService)
        self.ntfyService = NtfyService(tokenStore: tokenStore, authService: authService)

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

        self.notePadService = NotePadService(
            repository: notePadRepository,
            conversationRepository: conversationRepository,
            authService: authService
        )

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

        self.recoveryService = RecoveryService(
            api: RecoveryAPI(tokenStore: tokenStore),
            database: database,
            cryptoService: cryptoService,
            authService: authService,
            userRepository: userRepository,
            conversationRepository: conversationRepository,
            messageRepository: messageRepository,
            notePadRepository: notePadRepository,
            alarmRepository: alarmRepository,
            messagingService: messagingService
        )

        // MARK: Send handlers

        notePadService.setSendHandler { [weak messagingService] operation, conversation in
            try await messagingService?.sendNotePadOperation(operation, in: conversation)
        }

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

        invitationService.setSendHandler { [weak messagingService] payload, conversation in
            try await messagingService?.sendControlPayload(payload, kind: .invite, in: conversation)
        }
        let notePadService = self.notePadService
        invitationService.setFlushHandler { [weak messagingService, weak notePadService] conversation in
            await messagingService?.flushQueuedMessages(in: conversation)
            await notePadService?.flushPending(in: conversation)
        }

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
                receiptService?.applyRemote(payload, conversationId: conversation.id, ownerUserId: conversation.ownerUserId)
            },
            profile: { [weak profileService] payload, conversation, senderId in
                Task { await profileService?.applyRemote(payload, senderId: senderId, ownerUserId: conversation.ownerUserId) }
            },
            invite: { [weak invitationService] payload, conversation, senderId in
                invitationService?.applyRemote(payload, conversation: conversation, senderId: senderId, ownerUserId: conversation.ownerUserId)
            },
            call: { [weak callService] signal, conversation, senderId in
                Task { await callService?.handle(signal, from: senderId, conversation: conversation) }
            }
        )

        self.appLockService = AppLockService()
        self.accountDeletionService = AccountDeletionService(
            cryptoService: cryptoService,
            apiClient: apiClient,
            conversationRepository: conversationRepository,
            messageRepository: messageRepository,
            sessionRepository: sessionRepository,
            userRepository: userRepository,
            mediaEncryptionService: mediaEncryptionService,
            notePadRepository: notePadRepository,
            alarmRepository: alarmRepository
        )

        // MARK: Reconnect → catch up
        //
        // FIX: after the socket comes back, fetch what was queued while it was
        // down and send pad edits that couldn't go out. Skipped if a backfill
        // is already running (two at once could process the same envelope
        // concurrently).
        webSocketService.setReconnectHandler { [weak self] in
            Task { @MainActor in
                guard let self, let userId = self.authService.currentUserId else { return }
                if !self.messagingService.isSyncing {
                    await self.messagingService.backfillPendingEnvelopes(myUserId: userId)
                }
                await self.notePadService.flushAllPending()
            }
        }

        // MARK: Change forwarding

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
            recoveryService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ntfyService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(forwarded)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        messagingService.$incomingMessage
            .compactMap { $0?.conversationId }
            .sink { [weak self] conversationId in
                guard let self else { return }
                self.invitationService.reloadPending()
                self.presenceService.refreshContacts()
                Task { await self.profileService.ensureShared(conversationId: conversationId) }
            }
            .store(in: &cancellables)

        invitationService.changes
            .sink { [weak self] conversationId in
                guard let self else { return }
                self.presenceService.refreshContacts()
                Task { await self.profileService.ensureShared(conversationId: conversationId) }
            }
            .store(in: &cancellables)

        let pushService = self.pushService
        authService.setLogoutHandler { [weak self] departingUserId in
            guard let self else { return }
            // Read now: the session token is cleared right after this handler.
            pushService.unregister(bearer: tokenStore.currentToken)
            self.ntfyService.signedOut(bearer: tokenStore.currentToken)
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
                    self.presenceService.start()
                    self.messagingService.startListening()
                    self.invitationService.reloadPending()
                    Task {
                        await self.ntfyService.signedIn()
                        await self.alarmService.activate()
                        await self.pushService.register()
                        await self.pushService.upload()
                        await self.notePadService.flushAllPending()
                    }
                } else {
                    self.presenceService.stop()
                    self.messagingService.stopListening()
                    self.invitationService.reloadPending()
                }
            }
            .store(in: &cancellables)

        mediaEncryptionService.pruneCache()
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
