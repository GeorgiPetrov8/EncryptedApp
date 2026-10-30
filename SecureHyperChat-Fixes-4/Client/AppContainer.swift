import Foundation
import Combine
import GRDB
import UIKit
import os

/// Hand-rolled dependency container. Created once at app launch.
///
/// This version = ClientFixes + SessionRenewal + "ntfy only":
///   - `sessionRenewal` is wired in (it was missing from the ClientFixes file);
///   - Apple push is never registered (no paid account): no permission prompt
///     for remote notifications, no token upload. `pushService` stays only so
///     `AppDelegate` keeps compiling; delete both together when convenient.
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
    let sessionRenewal: SessionRenewalService
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
    /// Unused (no Apple push); kept for AppDelegate.
    let pushService: PushService
    let ntfyService: NtfyService
    let blockList: BlockListStore

    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "container")
    private var cancellables = Set<AnyCancellable>()

    private init(database: DatabaseManager) {
        self.database = database
        self.cryptoService = CryptoService()
        self.tenorService = TenorService()
        self.appearanceStore = AppearanceStore()
        self.blockList = BlockListStore()

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

        self.sessionRenewal = SessionRenewalService(
            authService: authService,
            apiClient: apiClient,
            cryptoService: cryptoService,
            tokenStore: tokenStore
        )

        self.pushService = PushService(apiClient: apiClient, authService: authService)
        self.ntfyService = NtfyService(tokenStore: tokenStore, authService: authService)

        self.invitationService = InvitationService(
            conversationRepository: conversationRepository,
            userRepository: userRepository,
            messageRepository: messageRepository,
            authService: authService,
            apiClient: apiClient,
            blockList: blockList
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
            authService: authService,
            blockList: blockList
        )

        let authService = self.authService
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
            messagingService: messagingService,
            // `ChallengeSigner` is a synchronous @MainActor closure: no `await`.
            // Only ever signs for the account that is signed in (S9).
            proveChallenge: { [cryptoService, weak authService] challenge in
                guard let me = authService?.currentUserId else { throw APIError.notAuthenticated }
                guard cryptoService.hasIdentity(forUserId: me) else { throw AuthError.noLocalIdentityForAccount }
                try cryptoService.loadIdentityFromKeychain(userId: me)
                return try cryptoService.signChallenge(challenge, expectedUserId: me)
            }
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

        appLockService.onLock = { [weak authService] in
            DecryptedMediaCache.shared.removeAll()
            authService?.lockStorage()
        }

        // MARK: Reconnect → catch up

        webSocketService.setReconnectHandler { [weak self] in
            Task { @MainActor in
                guard let self, let userId = self.authService.currentUserId else { return }
                if !self.messagingService.isSyncing {
                    await self.messagingService.backfillPendingEnvelopes(myUserId: userId)
                }
                await self.notePadService.flushAllPending()
            }
        }

        authService.$isStorageUnlocked
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, let userId = self.authService.currentUserId else { return }
                    if !self.messagingService.isSyncing {
                        await self.messagingService.backfillPendingEnvelopes(myUserId: userId)
                    }
                }
            }
            .store(in: &cancellables)

        // MARK: Change forwarding

        let forwarded: [AnyPublisher<Void, Never>] = [
            authService.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            sessionRenewal.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
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

        // Someone started recovering this account elsewhere (server notice, S2).
        NotificationCenter.default.publisher(for: .recoveryPendingNotice)
            .sink { [weak self] _ in
                Task { await self?.recoveryService.refreshEmailStatus() }
            }
            .store(in: &cancellables)

        authService.setLogoutHandler { [weak self] departingUserId in
            guard let self else { return }
            self.ntfyService.signedOut(bearer: tokenStore.currentToken)
            Self.revokeServerSession(bearer: tokenStore.currentToken)
            Task { await self.callService.hangUp() }
            self.messagingService.stopListening()
            self.presenceService.stop()
            self.mediaEncryptionService.clearCache(ownerUserId: departingUserId)
            self.profileService.clearMemory()
            self.notePadService.clearInMemoryState()
            self.alarmService.stopForLogout()
            self.messagingService.clearReceiveError()
            self.callService.clearError()
        }

        authService.$currentUserId
            .removeDuplicates()
            .sink { [weak self] userId in
                guard let self else { return }
                if userId != nil {
                    self.presenceService.start()
                    self.messagingService.startListening()
                    self.invitationService.reloadPending()
                    self.sessionRenewal.renew(force: false)
                    Task {
                        await self.ntfyService.signedIn()
                        await self.alarmService.activate()
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
        MediaExporter.purge(olderThan: 0)
    }

    private static func revokeServerSession(bearer: String?) {
        guard !NetworkConfiguration.useMockBackend,
              let bearer,
              let url = URL(string: "/auth/logout", relativeTo: NetworkConfiguration.baseURL)?.absoluteURL
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        var taskId = UIBackgroundTaskIdentifier.invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "logout") {
            UIApplication.shared.endBackgroundTask(taskId)
        }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1.5))
            for attempt in 0..<3 {
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse, http.statusCode < 500 { break }
                try? await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
            }
            await MainActor.run { UIApplication.shared.endBackgroundTask(taskId) }
        }
    }

    // MARK: Bootstrap

    static func tryBootstrap() -> Result<AppContainer, Error> {
        do {
            let database = try DatabaseManager()
            BackupExclusion.excludeAppData(databaseURL: databaseFileURL)
            ProtectedTemp.purge()
            return .success(AppContainer(database: database))
        } catch {
            return .failure(error)
        }
    }

    static var databaseFileURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("HyperChat.sqlite")
    }
}
