import Foundation
import Combine
import os

/// Raised when the server presents an identity that doesn't match what we pinned.
enum IdentityError: LocalizedError, Equatable {
    case identityChanged(userId: String)
    case identityChangeUnacknowledged(userId: String)

    var errorDescription: String? {
        switch self {
        case .identityChanged:
            return "This contact's security keys have changed. Verify the safety number before continuing."
        case .identityChangeUnacknowledged:
            return "This conversation is paused until you review the contact's changed security keys."
        }
    }
}

/// Reasons an inbound envelope couldn't be turned into a message (Bug #9).
enum ReceiveError: LocalizedError, Equatable {
    case noSessionForRatchetMessage(senderId: String)
    case notAuthenticated
    case decryptionFailed
    /// NEW (R2): the local storage key is still locked (Face ID not done yet).
    /// Transient — the envelope stays on the server and is fetched again later.
    case storageLocked

    var errorDescription: String? {
        switch self {
        case .noSessionForRatchetMessage:
            return "A message arrived for a conversation this device has no session for. Ask your contact to start a new conversation."
        case .notAuthenticated:
            return "A message arrived while no account was active."
        case .decryptionFailed:
            return "A message couldn't be decrypted. It may have been tampered with in transit."
        case .storageLocked:
            return "Unlock SecureHyperChat to receive messages."
        }
    }
}

struct MediaDisplayMetadata {
    let mediaType: MediaType
    let duration: TimeInterval?
    let waveform: [Float]?
}

/// Orchestrates everything needed to send and receive end-to-end encrypted messages.
///
/// Changes in this version:
///   - R1: an incoming message is only "consumed" once it is safely stored. The
///     ratchet state is written to disk *after* the message row, and if storing
///     fails the in-memory session is rolled back, so the redelivered envelope can
///     still be decrypted. Before, any error after decryption (storage key locked,
///     disk full) advanced the ratchet anyway and the message was lost for good.
///   - R2: nothing is processed while the storage key is locked; envelopes stay
///     queued on the server instead of turning into "couldn't be decrypted".
///   - S1: names come only from the server directory, never from a handshake.
///   - S34: blocked users' envelopes are acknowledged and dropped silently.
///   - I-07/S1: profile updates are accepted only from accepted contacts, so a
///     stranger can't push an avatar or name into the invitations screen.
///   - R27: a failed message is retried with its original id.
///   - S41: ids are logged as `.private`.
@MainActor
final class MessagingService: ObservableObject {
    @Published private(set) var incomingMessage: (conversationId: String, message: Message)?
    @Published private(set) var identityAlert: IdentityError?
    @Published private(set) var lastReceiveError: String?
    @Published private(set) var isListening = false
    @Published private(set) var isSyncing = false

    let conversationChanged = PassthroughSubject<String, Never>()

    private let cryptoService: CryptoService
    private let apiClient: APIClientProtocol
    private let webSocketService: WebSocketServiceProtocol
    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let sessionRepository: SessionRepository
    private let userRepository: UserRepository
    private let authService: AuthService
    private let syncCursors: SyncCursorStore
    private let mediaEncryptionService: MediaEncryptionService
    private let notePadService: NotePadService
    private let blockList: BlockListStore

    private let pendingHandshakes = PendingHandshakeStore()
    private var sendChains: [String: Task<Void, Never>] = [:]

    private var deliveryHandler: ((Message, Conversation) -> Void)?
    private var receiptHandler: ((ReceiptPayload, Conversation) -> Void)?
    private var profileHandler: ((ProfilePayload, Conversation, String) -> Void)?
    private var inviteHandler: ((InvitePayload, Conversation, String) -> Void)?
    private var callHandler: ((CallSignal, Conversation, String) -> Void)?

    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "messaging")
    private var listenerTask: Task<Void, Never>?

    private static let oneTimePreKeyLowWaterMark = 5

    init(
        cryptoService: CryptoService,
        apiClient: APIClientProtocol,
        webSocketService: WebSocketServiceProtocol,
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        sessionRepository: SessionRepository,
        userRepository: UserRepository,
        mediaEncryptionService: MediaEncryptionService,
        notePadService: NotePadService,
        authService: AuthService,
        syncCursors: SyncCursorStore = SyncCursorStore(),
        blockList: BlockListStore = BlockListStore()
    ) {
        self.cryptoService = cryptoService
        self.apiClient = apiClient
        self.webSocketService = webSocketService
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.sessionRepository = sessionRepository
        self.userRepository = userRepository
        self.mediaEncryptionService = mediaEncryptionService
        self.notePadService = notePadService
        self.authService = authService
        self.syncCursors = syncCursors
        self.blockList = blockList
    }

    func setControlHandlers(
        delivery: @escaping (Message, Conversation) -> Void,
        receipt: @escaping (ReceiptPayload, Conversation) -> Void,
        profile: @escaping (ProfilePayload, Conversation, String) -> Void,
        invite: @escaping (InvitePayload, Conversation, String) -> Void,
        call: @escaping (CallSignal, Conversation, String) -> Void
    ) {
        deliveryHandler = delivery
        receiptHandler = receipt
        profileHandler = profile
        inviteHandler = invite
        callHandler = call
    }

    // MARK: Listening

    func startListening() {
        guard let myUserId = authService.currentUserId else {
            logger.error("startListening called with no active account; listener not started")
            isListening = false
            return
        }
        listenerTask?.cancel()
        isListening = true

        let liveEvents = webSocketService.events(for: myUserId)

        listenerTask = Task { [weak self] in
            guard let self else { return }
            await self.backfillPendingEnvelopes(myUserId: myUserId)

            for await envelope in liveEvents {
                do {
                    try await self.handleIncoming(envelope)
                    try? await self.apiClient.acknowledge(userId: myUserId, envelopeIds: [envelope.id])
                } catch {
                    let recorded = await self.handleReceiveFailure(error, envelope: envelope, myUserId: myUserId)
                    if recorded {
                        try? await self.apiClient.acknowledge(userId: myUserId, envelopeIds: [envelope.id])
                    }
                }
            }
            self.isListening = false
        }

        Task { await performStartupMaintenance() }
    }

    func stopListening() {
        listenerTask?.cancel()
        listenerTask = nil
        isListening = false
        if let myUserId = authService.currentUserId {
            webSocketService.disconnect(userId: myUserId)
        }
    }

    func clearReceiveError() {
        lastReceiveError = nil
    }

    // MARK: Offline backfill (Bug #12)

    func backfillPendingEnvelopes(myUserId: String) async {
        // R2: wait for Face ID; `AppContainer` calls this again once unlocked.
        guard authService.isStorageUnlocked else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let page = try await apiClient.fetchPendingEnvelopes(
                userId: myUserId,
                since: syncCursors.cursor(for: myUserId)
            )
            guard !page.envelopes.isEmpty else { return }

            var delivered: [String] = []
            var allDurable = true

            for envelope in page.envelopes {
                do {
                    try await handleIncoming(envelope)
                    delivered.append(envelope.id)
                } catch {
                    let recorded = await handleReceiveFailure(error, envelope: envelope, myUserId: myUserId)
                    if recorded {
                        delivered.append(envelope.id)
                    } else {
                        allDurable = false
                    }
                }
            }

            if allDurable {
                syncCursors.advance(to: page.cursor, for: myUserId)
            }
            try? await apiClient.acknowledge(userId: myUserId, envelopeIds: delivered)
            logger.info("Backfilled \(delivered.count, privacy: .public)/\(page.envelopes.count, privacy: .public) envelopes")
        } catch {
            logger.error("Backfill sync failed; will retry on next listen")
        }
    }

    // MARK: Startup maintenance

    private func performStartupMaintenance() async {
        await rotateSignedPreKeyIfNeeded()
        await replenishOneTimePreKeysIfNeeded()
        do {
            try messageRepository.pruneProcessedEnvelopes()
        } catch {
            logger.error("Pruning processed envelopes failed")
        }
    }

    func rotateSignedPreKeyIfNeeded() async {
        guard let myUserId = authService.currentUserId else { return }
        do {
            guard let rotated = try cryptoService.rotateSignedPreKeyIfNeeded() else { return }
            try await apiClient.publishSignedPreKey(SignedPreKeyUpload(
                userId: myUserId,
                signedPreKeyId: rotated.id,
                signedPreKey: rotated.publicKey.rawRepresentation,
                signedPreKeySignature: rotated.signature
            ))
        } catch {
            logger.error("Signed prekey rotation failed")
        }
    }

    func replenishOneTimePreKeysIfNeeded() async {
        guard let myUserId = authService.currentUserId else { return }
        guard cryptoService.remainingOneTimePreKeyCount < Self.oneTimePreKeyLowWaterMark else { return }
        do {
            let fresh = try cryptoService.generateOneTimePreKeys(count: CryptoService.oneTimePreKeyBatchSize)
            try await apiClient.replenishOneTimePreKeys(userId: myUserId, keys: fresh)
        } catch {
            logger.error("One-time prekey replenish failed")
        }
    }

    func reestablishSessions() async {
        guard let me = authService.currentUserId,
              let conversations = try? conversationRepository.fetchAllSortedByRecentActivity(ownerUserId: me)
        else { return }

        for conversation in conversations where conversation.relationshipState == .accepted {
            let ping = ReceiptPayload(kind: .delivered, messageIds: [], conversationId: conversation.id, timestamp: Date())
            do {
                try await sendControlPayload(ping, kind: .receipt, in: conversation)
            } catch {
                logger.error("Couldn't re-establish a session after restore; it will happen on the next message")
            }
        }
    }

    // MARK: Identity pinning (Bug #2) and contact caching (Bug #11)

    /// `trustedUsername` must come from the server (bundle / directory) or be nil.
    private func pinOrVerifyIdentity(
        ownerUserId: String,
        userId: String,
        trustedUsername: String?,
        agreementKey: Data,
        signingKey: Data
    ) throws {
        let result = try userRepository.pinOrCompareIdentity(
            ownerUserId: ownerUserId,
            userId: userId,
            username: trustedUsername,
            agreementKey: agreementKey,
            signingKey: signingKey
        )
        switch result {
        case .pinned, .matches:
            return
        case .changed:
            logger.fault("Identity key mismatch for \(userId, privacy: .private)")
            throw IdentityError.identityChanged(userId: userId)
        case .changePending:
            throw IdentityError.identityChangeUnacknowledged(userId: userId)
        }
    }

    /// FIX (S1): the contact's name comes from the server directory.
    ///
    /// It used to take `handshake.senderUsername` — a field the sender fills in —
    /// and overwrite the stored name with it, so anyone could appear as anyone. Now
    /// the directory is asked whenever the name is missing or still the id-prefix
    /// placeholder; an existing directory name is never replaced by a peer.
    @discardableResult
    private func ensureContact(ownerUserId: String, userId: String) async -> User? {
        let existing = try? userRepository.fetch(ownerUserId: ownerUserId, id: userId)
        if let existing, !existing.hasPlaceholderUsername { return existing }

        guard let entry = try? await apiClient.fetchDirectoryEntry(userId: userId),
              entry.userId == userId else { return existing }

        if existing == nil {
            try? pinOrVerifyIdentity(
                ownerUserId: ownerUserId,
                userId: entry.userId,
                trustedUsername: entry.username,
                agreementKey: entry.identityAgreementKey,
                signingKey: entry.identitySigningKey
            )
        } else {
            try? userRepository.updateUsername(ownerUserId: ownerUserId, userId: userId, username: entry.username)
        }
        return try? userRepository.fetch(ownerUserId: ownerUserId, id: userId)
    }

    func acknowledgeIdentityChange(userId: String) throws {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }
        try userRepository.acknowledgeIdentityChange(ownerUserId: myUserId, userId: userId)
        identityAlert = nil
    }

    func setVerified(_ verified: Bool, userId: String) throws {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }
        try userRepository.setVerified(verified, ownerUserId: myUserId, userId: userId)
    }

    func contact(_ userId: String) throws -> User? {
        guard let myUserId = authService.currentUserId else { return nil }
        return try userRepository.fetch(ownerUserId: myUserId, id: userId)
    }

    func safetyNumber(forPeerId peerId: String) throws -> String? {
        guard let identity = cryptoService.identity,
              let peer = try contact(peerId),
              let peerSigningKey = peer.identitySigningKey else { return nil }
        return SafetyNumber.format(
            myAgreementKey: identity.agreementPublicKey.rawRepresentation,
            mySigningKey: identity.signingPublicKey.rawRepresentation,
            peerAgreementKey: peer.publicKey,
            peerSigningKey: peerSigningKey
        )
    }

    func pendingSafetyNumber(forPeerId peerId: String) throws -> String? {
        guard let identity = cryptoService.identity,
              let peer = try contact(peerId),
              let pendingAgreement = peer.pendingIdentityAgreementKey,
              let pendingSigning = peer.pendingIdentitySigningKey else { return nil }
        return SafetyNumber.format(
            myAgreementKey: identity.agreementPublicKey.rawRepresentation,
            mySigningKey: identity.signingPublicKey.rawRepresentation,
            peerAgreementKey: pendingAgreement,
            peerSigningKey: pendingSigning
        )
    }

    func peer(for conversation: Conversation) throws -> User? {
        guard let myUserId = authService.currentUserId,
              let peerId = conversation.otherParticipant(myUserId: myUserId) else { return nil }
        return try userRepository.fetch(ownerUserId: myUserId, id: peerId)
    }

    // MARK: Blocking (S34)

    func block(userId: String) {
        guard let me = authService.currentUserId else { return }
        blockList.block(userId, ownerUserId: me)
    }

    func unblock(userId: String) {
        guard let me = authService.currentUserId else { return }
        blockList.unblock(userId, ownerUserId: me)
    }

    func isBlocked(userId: String) -> Bool {
        guard let me = authService.currentUserId else { return false }
        return blockList.isBlocked(userId, ownerUserId: me)
    }

    // MARK: Invitation gate

    func relationshipState(of conversation: Conversation) -> RelationshipState {
        guard let myUserId = authService.currentUserId,
              let fresh = try? conversationRepository.fetch(id: conversation.id, ownerUserId: myUserId)
        else { return conversation.relationshipState }
        return fresh.relationshipState
    }

    // MARK: Sending — shared transport core

    private func serialized<T>(peerId: String, _ operation: @escaping () async throws -> T) async throws -> T {
        let previous = sendChains[peerId]
        let task = Task { () async throws -> T in
            _ = await previous?.value
            return try await operation()
        }
        sendChains[peerId] = Task { _ = try? await task.value }
        return try await task.value
    }

    private func transmitEnvelope(
        id envelopeId: String,
        plaintext: Data,
        contentType: EnvelopePayloadKind,
        in conversation: Conversation,
        createdAt: Date
    ) async throws {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }
        guard let peerId = conversation.otherParticipant(myUserId: myUserId) else { throw APIError.userNotFound }

        try await serialized(peerId: peerId) { [self] in
            try await performTransmit(
                envelopeId: envelopeId,
                plaintext: plaintext,
                contentType: contentType,
                conversationId: conversation.id,
                myUserId: myUserId,
                peerId: peerId,
                createdAt: createdAt
            )
        }
    }

    private func performTransmit(
        envelopeId: String,
        plaintext: Data,
        contentType: EnvelopePayloadKind,
        conversationId: String,
        myUserId: String,
        peerId: String,
        createdAt: Date
    ) async throws {
        guard let identity = cryptoService.identity else { throw APIError.notAuthenticated }

        if let peer = try userRepository.fetch(ownerUserId: myUserId, id: peerId),
           peer.hasUnacknowledgedIdentityChange {
            throw IdentityError.identityChangeUnacknowledged(userId: peerId)
        }

        var createdHandshake: HandshakeInitPayload?

        if cryptoService.session(for: peerId) == nil {
            if let record = try sessionRepository.fetch(ownerUserId: myUserId, otherUserId: peerId) {
                try cryptoService.restoreSession(encryptedState: record.encryptedState, for: peerId)
            } else {
                let bundle = try await apiClient.fetchPreKeyBundle(forUserId: peerId)
                guard bundle.userId == peerId else { throw APIError.userNotFound }
                // The bundle is served by our server for this user id: its username
                // is trustworthy.
                try pinOrVerifyIdentity(
                    ownerUserId: myUserId,
                    userId: peerId,
                    trustedUsername: bundle.username,
                    agreementKey: bundle.identityAgreementKey,
                    signingKey: bundle.identitySigningKey
                )

                let result = try X3DH.initiate(myIdentity: identity, bundle: bundle)
                let session = try DoubleRatchetSession(
                    initiatorRootKey: result.rootKey,
                    peerSignedPreKeyPublic: try CurveKeyHelper.publicKey(from: bundle.signedPreKey)
                )
                cryptoService.setSession(session, for: peerId)

                createdHandshake = HandshakeInitPayload(
                    identityAgreementKey: identity.agreementPublicKey.rawRepresentation,
                    identitySigningKey: identity.signingPublicKey.rawRepresentation,
                    senderUsername: authService.currentUsername,
                    ephemeralPublicKey: result.ephemeralPublicKey.rawRepresentation,
                    usedSignedPreKeyId: bundle.signedPreKeyId,
                    usedOneTimePreKeyId: result.usedOneTimePreKeyId
                )
            }
        }

        guard let session = cryptoService.session(for: peerId) else { throw CryptoError.sessionNotReady }
        let ratchetMessage = try session.encrypt(plaintext: plaintext)
        try persistSessionState(for: peerId, ownerUserId: myUserId)

        let outgoingHandshake = createdHandshake
            ?? pendingHandshakes.pending(ownerUserId: myUserId, peerId: peerId)
        let outgoingKind: EnvelopeKind = outgoingHandshake == nil ? .ratchet : .handshake

        let envelope = EnvelopeDTO(
            id: envelopeId,
            conversationId: conversationId,
            senderId: myUserId,
            recipientId: peerId,
            kind: outgoingKind,
            handshake: outgoingHandshake,
            ratchetMessage: try ratchetMessage.serialized(),
            contentType: contentType,
            createdAt: createdAt
        )

        if let createdHandshake {
            pendingHandshakes.store(createdHandshake, ownerUserId: myUserId, peerId: peerId)
        }

        do {
            try await apiClient.sendMessage(envelope)
        } catch {
            if createdHandshake != nil {
                rollbackHandshakeSession(peerId: peerId, ownerUserId: myUserId)
                pendingHandshakes.clear(ownerUserId: myUserId, peerId: peerId)
            }
            throw error
        }
    }

    private func rollbackHandshakeSession(peerId: String, ownerUserId: String) {
        cryptoService.clearSession(for: peerId)
        do {
            try sessionRepository.delete(ownerUserId: ownerUserId, otherUserId: peerId)
        } catch {
            logger.error("Couldn't delete a rolled-back session row")
        }
    }

    func clearPendingHandshakes(ownerUserId: String) {
        pendingHandshakes.clearAll(ownerUserId: ownerUserId)
    }

    // MARK: Sending — chat messages

    func sendText(_ text: String, replyTo: ReplyReference? = nil, in conversation: Conversation) async throws {
        let payload = TextPayload(text: text, replyTo: replyTo)
        try await send(plaintext: try payload.encoded(), contentType: .text, in: conversation)
    }

    func sendGIF(_ gif: GIFAttachment, replyTo: ReplyReference? = nil, in conversation: Conversation) async throws {
        let payload = TextPayload(text: "🎞️ GIF", replyTo: replyTo, gif: gif)
        try await send(plaintext: try payload.encoded(), contentType: .text, in: conversation)
    }

    func sendMedia(
        rawData: Data,
        thumbnail: Data?,
        mediaType: MediaType,
        duration: TimeInterval? = nil,
        waveform: [Float]? = nil,
        in conversation: Conversation
    ) async throws {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }
        try requireCanCompose(in: conversation)

        let prepared = try await mediaEncryptionService.prepareForSending(
            rawData: rawData,
            thumbnail: thumbnail,
            mediaType: mediaType,
            duration: duration,
            waveform: waveform,
            ownerUserId: myUserId
        )

        let contentType: MessageContentType
        switch mediaType {
        case .image: contentType = .image
        case .video: contentType = .video
        case .audio, .document: contentType = .file
        }

        try await send(
            plaintext: prepared.messagePayload,
            contentType: contentType,
            in: conversation,
            media: prepared.pendingMediaItem
        )
    }

    private func requireCanCompose(in conversation: Conversation) throws {
        switch relationshipState(of: conversation) {
        case .accepted, .invitedByMe: return
        case .invitedByThem: throw InvitationError.mustAcceptFirst
        case .declined: throw InvitationError.declined
        }
    }

    func send(
        plaintext: Data,
        contentType: MessageContentType,
        in conversation: Conversation,
        media: MediaItem? = nil
    ) async throws {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }
        try requireCanCompose(in: conversation)
        let state = relationshipState(of: conversation)

        let localMessageId = UUID().uuidString
        let createdAt = Date()
        let storedCiphertext = try cryptoService.encryptForStorage(plaintext)

        let message = Message(
            id: localMessageId,
            ownerUserId: myUserId,
            conversationId: conversation.id,
            senderId: myUserId,
            encryptedContent: storedCiphertext,
            contentType: contentType,
            deliveryStatus: .sending,
            createdAt: createdAt
        )
        try messageRepository.insert(message, media: media)

        guard state == .accepted else { return }
        try await transmitStored(message, plaintext: plaintext, in: conversation)
    }

    private func transmitStored(_ message: Message, plaintext: Data, in conversation: Conversation) async throws {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }
        do {
            try await transmitEnvelope(
                id: message.id,
                plaintext: plaintext,
                contentType: message.contentType.asEnvelopePayloadKind,
                in: conversation,
                createdAt: message.createdAt
            )
            try messageRepository.updateDeliveryStatus(messageId: message.id, ownerUserId: myUserId, status: .sent)
        } catch {
            try? messageRepository.updateDeliveryStatus(messageId: message.id, ownerUserId: myUserId, status: .failed)
            throw error
        }
    }

    /// FIX (R27): re-sends a failed message **with its original id**.
    ///
    /// The chat's "Retry" used to call `sendText` again, which creates a new
    /// message with a new id: the failed row stayed in the chat, and if the first
    /// attempt had in fact reached the server (only the response was lost) the
    /// recipient got the text twice. With the same id the server and the
    /// recipient's replay protection both treat it as the same message.
    func retry(messageId: String, in conversation: Conversation) async throws {
        guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
        guard let message = try messageRepository.fetch(messageId: messageId, ownerUserId: me),
              message.senderId == me,
              message.conversationId == conversation.id,
              message.deliveryStatus == .failed || message.deliveryStatus == .sending
        else { return }
        guard relationshipState(of: conversation) == .accepted else { return }
        let plaintext = try cryptoService.decryptFromStorage(message.encryptedContent)
        try messageRepository.updateDeliveryStatus(messageId: messageId, ownerUserId: me, status: .sending)
        conversationChanged.send(conversation.id)
        try await transmitStored(message, plaintext: plaintext, in: conversation)
        conversationChanged.send(conversation.id)
    }

    func flushQueuedMessages(in conversation: Conversation) async {
        guard let myUserId = authService.currentUserId,
              relationshipState(of: conversation) == .accepted else { return }

        let queued = ((try? messageRepository.fetchMessages(
            conversationId: conversation.id, ownerUserId: myUserId
        )) ?? []).filter { $0.senderId == myUserId && $0.deliveryStatus == .sending }

        for message in queued {
            do {
                let plaintext = try cryptoService.decryptFromStorage(message.encryptedContent)
                try await transmitStored(message, plaintext: plaintext, in: conversation)
            } catch {
                logger.error("Couldn't send a queued message after acceptance")
            }
        }
        conversationChanged.send(conversation.id)
    }

    // MARK: Editing and deleting

    func canEdit(_ message: Message) -> Bool {
        guard let me = authService.currentUserId else { return false }
        return message.senderId == me
            && message.contentType == .text
            && !message.isUndecryptable
            && message.deliveryStatus != .failed
            && Date().timeIntervalSince(message.createdAt) <= MessageEditPolicy.window
            && textContent(for: message)?.gif == nil
    }

    func editMessage(messageId: String, newText: String, in conversation: Conversation) async throws {
        guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MessageEditError.empty }
        guard let message = try messageRepository.fetch(messageId: messageId, ownerUserId: me),
              message.senderId == me, message.contentType == .text, !message.isUndecryptable
        else { throw MessageEditError.notEditable }
        guard Date().timeIntervalSince(message.createdAt) <= MessageEditPolicy.window else {
            throw MessageEditError.windowExpired
        }

        let previous = textContent(for: message)
        guard previous?.gif == nil else { throw MessageEditError.notEditable }
        guard previous?.text != text else { return }

        let editedAt = Date()
        let payload = TextPayload(text: text, replyTo: previous?.replyTo)
        try messageRepository.updateContent(
            messageId: messageId,
            ownerUserId: me,
            encryptedContent: try cryptoService.encryptForStorage(try payload.encoded()),
            editedAt: editedAt
        )
        conversationChanged.send(conversation.id)

        guard message.deliveryStatus != .sending else { return }
        try await sendControlPayload(
            EditPayload(messageId: messageId, text: text, editedAt: editedAt),
            kind: .edit,
            in: conversation,
            createdAt: editedAt
        )
    }

    func deleteMessageLocally(messageId: String, conversationId: String) throws {
        guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
        try messageRepository.delete(messageId: messageId, ownerUserId: me)
        conversationChanged.send(conversationId)
    }

    // MARK: Reactions

    func sendReaction(messageId: String, emoji: String?, in conversation: Conversation) async throws {
        guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
        guard let message = try messageRepository.fetch(messageId: messageId, ownerUserId: me),
              message.conversationId == conversation.id,
              !message.isUndecryptable
        else { throw ReactionError.notReactable }
        if let emoji, !ReactionPayload.isValidEmoji(emoji) { throw ReactionError.invalidEmoji }

        let now = Date()
        try messageRepository.upsertReactionIfNewer(MessageReaction(
            ownerUserId: me,
            conversationId: conversation.id,
            messageId: messageId,
            reactorId: me,
            emoji: emoji ?? "",
            updatedAt: now
        ))
        conversationChanged.send(conversation.id)

        guard relationshipState(of: conversation) == .accepted else { return }
        try await sendControlPayload(
            ReactionPayload(messageId: messageId, emoji: emoji, reactedAt: now),
            kind: .reaction,
            in: conversation,
            createdAt: now
        )
    }

    func reactions(in conversationId: String) -> [MessageReaction] {
        guard let me = authService.currentUserId else { return [] }
        return (try? messageRepository.fetchReactions(conversationId: conversationId, ownerUserId: me)) ?? []
    }

    // MARK: Sending — control messages

    func sendNotePadOperation(_ operation: NotePadOperation, in conversation: Conversation) async throws {
        try await sendControlPayload(operation, kind: .notePad, in: conversation, createdAt: operation.updatedAt)
    }

    func sendControlPayload<T: Encodable>(
        _ payload: T,
        kind: EnvelopePayloadKind,
        in conversation: Conversation,
        createdAt: Date = Date()
    ) async throws {
        precondition(kind.isControlMessage, "Chat content must go through send(plaintext:...)")
        if kind != .invite {
            guard relationshipState(of: conversation).allowsSending else {
                throw InvitationError.notAccepted
            }
        }
        let plaintext = try JSONEncoder().encode(payload)
        try await transmitEnvelope(
            id: UUID().uuidString,
            plaintext: plaintext,
            contentType: kind,
            in: conversation,
            createdAt: createdAt
        )
    }

    // MARK: Receiving

    private func respondToHandshake(
        _ handshake: HandshakeInitPayload,
        senderId: String,
        myUserId: String,
        identity: IdentityKeyPair
    ) async throws -> DoubleRatchetSession {
        // S1: the handshake's `senderUsername` is NOT trusted for the name.
        try pinOrVerifyIdentity(
            ownerUserId: myUserId,
            userId: senderId,
            trustedUsername: nil,
            agreementKey: handshake.identityAgreementKey,
            signingKey: handshake.identitySigningKey
        )
        let mySignedPreKey = try cryptoService.signedPreKey(withId: handshake.usedSignedPreKeyId)
        let myOneTimePreKey = try handshake.usedOneTimePreKeyId.flatMap {
            try cryptoService.consumeOneTimePreKey(id: $0)
        }
        let rootKey = try X3DH.respond(
            myIdentity: identity,
            mySignedPreKey: mySignedPreKey.privateKey,
            myOneTimePreKey: myOneTimePreKey,
            aliceIdentityAgreementKey: handshake.identityAgreementKey,
            aliceEphemeralKey: handshake.ephemeralPublicKey
        )
        await replenishOneTimePreKeysIfNeeded()
        return DoubleRatchetSession(responderRootKey: rootKey, mySignedPreKeyPair: mySignedPreKey.privateKey)
    }

    private func decryptEnvelope(_ envelope: EnvelopeDTO, myUserId: String, identity: IdentityKeyPair) async throws -> Data {
        let senderId = envelope.senderId

        if cryptoService.session(for: senderId) == nil,
           let record = try sessionRepository.fetch(ownerUserId: myUserId, otherUserId: senderId) {
            try cryptoService.restoreSession(encryptedState: record.encryptedState, for: senderId)
        }

        let ratchetMessage = try RatchetMessage.deserialize(envelope.ratchetMessage)

        if let existing = cryptoService.session(for: senderId) {
            let snapshot = try? cryptoService.exportEncryptedState(for: senderId)
            do {
                return try existing.decrypt(ratchetMessage)
            } catch {
                guard envelope.kind == .handshake, let handshake = envelope.handshake else { throw error }
                do {
                    let fresh = try await respondToHandshake(handshake, senderId: senderId, myUserId: myUserId, identity: identity)
                    let plaintext = try fresh.decrypt(ratchetMessage)
                    cryptoService.setSession(fresh, for: senderId)
                    logger.info("Peer restarted their session; rebuilt ours from the handshake")
                    return plaintext
                } catch {
                    if let snapshot { try? cryptoService.restoreSession(encryptedState: snapshot, for: senderId) }
                    throw error
                }
            }
        }

        guard envelope.kind == .handshake, let handshake = envelope.handshake else {
            throw ReceiveError.noSessionForRatchetMessage(senderId: senderId)
        }
        let fresh = try await respondToHandshake(handshake, senderId: senderId, myUserId: myUserId, identity: identity)
        let plaintext = try fresh.decrypt(ratchetMessage)
        cryptoService.setSession(fresh, for: senderId)
        return plaintext
    }

    /// Puts the in-memory session back to what is on disk (R1): the state before
    /// this envelope was decrypted.
    private func rollbackSession(peerId: String, ownerUserId: String) {
        if let record = try? sessionRepository.fetch(ownerUserId: ownerUserId, otherUserId: peerId) {
            try? cryptoService.restoreSession(encryptedState: record.encryptedState, for: peerId)
        } else {
            cryptoService.clearSession(for: peerId)
        }
    }

    private func handleIncoming(_ envelope: EnvelopeDTO) async throws {
        guard let myUserId = authService.currentUserId else { throw ReceiveError.notAuthenticated }
        guard let identity = cryptoService.identity else { throw ReceiveError.notAuthenticated }
        // R2: without the storage key nothing can be stored; leave it on the server.
        guard authService.isStorageUnlocked else { throw ReceiveError.storageLocked }

        if try messageRepository.isEnvelopeProcessed(
            envelopeId: envelope.id, recipientUserId: myUserId, senderId: envelope.senderId
        ) {
            return
        }

        // S34: silently dropped. Marked processed so it's acknowledged.
        if blockList.isBlocked(envelope.senderId, ownerUserId: myUserId) {
            _ = try messageRepository.markEnvelopeProcessed(
                envelopeId: envelope.id, recipientUserId: myUserId, senderId: envelope.senderId
            )
            return
        }

        let plaintext = try await decryptEnvelope(envelope, myUserId: myUserId, identity: identity)

        // From here on the ratchet has advanced in memory only. Everything that can
        // fail runs before the session is written; on failure the session is put
        // back so the server's redelivery can still be decrypted (R1).
        do {
            try await storeDecrypted(envelope, plaintext: plaintext, myUserId: myUserId)
            try persistSessionState(for: envelope.senderId, ownerUserId: myUserId)
            pendingHandshakes.clear(ownerUserId: myUserId, peerId: envelope.senderId)
        } catch {
            rollbackSession(peerId: envelope.senderId, ownerUserId: myUserId)
            throw PostDecryptFailure(underlying: error)
        }
    }

    /// The envelope decrypted fine but couldn't be stored. It must stay on the
    /// server (it will be decrypted again on the next delivery), never become an
    /// "undecryptable" placeholder.
    private struct PostDecryptFailure: Error {
        let underlying: Error
    }

    private func storeDecrypted(_ envelope: EnvelopeDTO, plaintext: Data, myUserId: String) async throws {
        await ensureContact(ownerUserId: myUserId, userId: envelope.senderId)

        let isControl = envelope.contentType.isControlMessage
        if isControl && envelope.contentType != .invite {
            guard let existing = try conversationRepository.findDirectConversation(
                ownerUserId: myUserId, userA: myUserId, userB: envelope.senderId
            ) else {
                _ = try messageRepository.markEnvelopeProcessed(
                    envelopeId: envelope.id, recipientUserId: myUserId, senderId: envelope.senderId
                )
                return
            }
            try handleControlMessage(envelope, plaintext: plaintext, conversation: existing, myUserId: myUserId)
            return
        }

        var conversation = try await resolveConversation(
            with: envelope, plaintextPeerId: envelope.senderId, myUserId: myUserId
        )

        if isControl {
            try handleControlMessage(envelope, plaintext: plaintext, conversation: conversation, myUserId: myUserId)
            return
        }

        guard let messageContentType = envelope.contentType.asMessageContentType else {
            logger.fault("Envelope contentType had no MessageContentType mapping")
            return
        }

        // Encrypted for storage BEFORE anything is written: this is the step that
        // fails when the storage key is unavailable.
        let storedCiphertext = try cryptoService.encryptForStorage(plaintext)

        if conversation.relationshipState == .invitedByMe {
            conversation.relationshipState = .accepted
            conversation.inviteRespondedAt = Date()
            try conversationRepository.upsert(conversation)
            let accepted = conversation
            Task { await self.flushQueuedMessages(in: accepted) }
            conversationChanged.send(conversation.id)
        }

        let message = Message(
            id: envelope.id,
            ownerUserId: myUserId,
            conversationId: conversation.id,
            senderId: envelope.senderId,
            encryptedContent: storedCiphertext,
            contentType: messageContentType,
            deliveryStatus: .delivered,
            createdAt: min(envelope.createdAt, Date().addingTimeInterval(5 * 60))
        )

        let media = makeMediaItemIfNeeded(
            plaintext: plaintext,
            messageContentType: messageContentType,
            envelopeId: envelope.id,
            myUserId: myUserId,
            createdAt: message.createdAt
        )

        let inserted = try messageRepository.insertIfNotProcessed(
            message,
            media: media,
            envelopeId: envelope.id,
            recipientUserId: myUserId,
            senderId: envelope.senderId
        )
        guard inserted else { return }

        incomingMessage = (conversation.id, message)
        deliveryHandler?(message, conversation)
    }

    private func handleControlMessage(
        _ envelope: EnvelopeDTO,
        plaintext: Data,
        conversation: Conversation,
        myUserId: String
    ) throws {
        let recorded = try messageRepository.markEnvelopeProcessed(
            envelopeId: envelope.id, recipientUserId: myUserId, senderId: envelope.senderId
        )
        guard recorded else { return }

        let decoder = JSONDecoder()
        switch envelope.contentType {
        case .notePad:
            guard let operation = try? decoder.decode(NotePadOperation.self, from: plaintext) else { return }
            notePadService.applyRemoteOperation(operation, conversationId: conversation.id, ownerUserId: myUserId)

        case .receipt:
            guard let payload = try? decoder.decode(ReceiptPayload.self, from: plaintext) else { return }
            receiptHandler?(payload, conversation)

        case .profile:
            // Only from accepted contacts: a stranger's invitation must not be able
            // to push a name or (possibly hostile) image into the invitations list.
            guard conversation.relationshipState == .accepted,
                  let payload = try? decoder.decode(ProfilePayload.self, from: plaintext) else { return }
            profileHandler?(payload, conversation, envelope.senderId)

        case .invite:
            guard let payload = try? decoder.decode(InvitePayload.self, from: plaintext) else { return }
            inviteHandler?(payload, conversation, envelope.senderId)

        case .call:
            guard let signal = try? decoder.decode(CallSignal.self, from: plaintext) else { return }
            callHandler?(signal, conversation, envelope.senderId)

        case .edit:
            guard let payload = try? decoder.decode(EditPayload.self, from: plaintext) else { return }
            try applyRemoteEdit(payload, from: envelope.senderId, conversation: conversation, myUserId: myUserId)

        case .reaction:
            guard let payload = try? decoder.decode(ReactionPayload.self, from: plaintext) else { return }
            try applyRemoteReaction(payload, from: envelope.senderId, conversation: conversation, myUserId: myUserId)

        case .text, .image, .video, .file:
            break
        }
    }

    private func applyRemoteEdit(_ edit: EditPayload, from senderId: String, conversation: Conversation, myUserId: String) throws {
        let text = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let original = try messageRepository.fetch(messageId: edit.messageId, ownerUserId: myUserId),
              original.senderId == senderId,
              original.conversationId == conversation.id,
              original.contentType == .text,
              !original.isUndecryptable,
              textContent(for: original)?.gif == nil,
              edit.editedAt.timeIntervalSince(original.createdAt) <= MessageEditPolicy.window + MessageEditPolicy.receiveGrace
        else { return }

        let payload = TextPayload(text: text, replyTo: textContent(for: original)?.replyTo)
        try messageRepository.updateContent(
            messageId: original.id,
            ownerUserId: myUserId,
            encryptedContent: try cryptoService.encryptForStorage(try payload.encoded()),
            editedAt: min(edit.editedAt, Date())
        )
        conversationChanged.send(conversation.id)
    }

    private func applyRemoteReaction(_ reaction: ReactionPayload, from senderId: String, conversation: Conversation, myUserId: String) throws {
        if let emoji = reaction.emoji, !ReactionPayload.isValidEmoji(emoji) { return }
        guard let original = try messageRepository.fetch(messageId: reaction.messageId, ownerUserId: myUserId),
              original.conversationId == conversation.id,
              !original.isUndecryptable
        else { return }

        let changed = try messageRepository.upsertReactionIfNewer(MessageReaction(
            ownerUserId: myUserId,
            conversationId: conversation.id,
            messageId: original.id,
            reactorId: senderId,
            emoji: reaction.emoji ?? "",
            updatedAt: min(reaction.reactedAt, Date().addingTimeInterval(5 * 60))
        ))
        if changed { conversationChanged.send(conversation.id) }
    }

    private func makeMediaItemIfNeeded(
        plaintext: Data,
        messageContentType: MessageContentType,
        envelopeId: String,
        myUserId: String,
        createdAt: Date
    ) -> MediaItem? {
        guard messageContentType != .text else { return nil }
        do {
            // Validates the media id (S31): a malformed one never becomes a path.
            return try mediaEncryptionService.makeReceivedMediaItem(
                payloadData: plaintext,
                messageId: envelopeId,
                ownerUserId: myUserId,
                createdAt: createdAt
            )
        } catch {
            logger.error("Inbound media payload was invalid; stored without a media row")
            return nil
        }
    }

    @discardableResult
    private func handleReceiveFailure(_ error: Error, envelope: EnvelopeDTO, myUserId: String) async -> Bool {
        logger.error("Failed to process an envelope: \(String(describing: type(of: error)), privacy: .public)")

        // R2: transient — keep it queued, no placeholder, no error banner.
        if let receiveError = error as? ReceiveError, receiveError == .storageLocked {
            return false
        }
        // R1: decrypted but not stored — the session was rolled back; leave it
        // queued so the next delivery succeeds.
        if error is PostDecryptFailure {
            return false
        }

        if let identityError = error as? IdentityError {
            identityAlert = identityError
            lastReceiveError = identityError.localizedDescription
            return false
        }

        if envelope.contentType.isControlMessage {
            _ = try? messageRepository.markEnvelopeProcessed(
                envelopeId: envelope.id, recipientUserId: myUserId, senderId: envelope.senderId
            )
            return true
        }

        lastReceiveError = (error as? LocalizedError)?.errorDescription
            ?? ReceiveError.decryptionFailed.localizedDescription

        return await insertUndecryptablePlaceholder(for: envelope, myUserId: myUserId)
    }

    @discardableResult
    private func insertUndecryptablePlaceholder(for envelope: EnvelopeDTO, myUserId: String) async -> Bool {
        do {
            guard let conversation = try? await resolveConversation(
                with: envelope, plaintextPeerId: envelope.senderId, myUserId: myUserId
            ) else { return false }

            let placeholder = Message(
                id: envelope.id,
                ownerUserId: myUserId,
                conversationId: conversation.id,
                senderId: envelope.senderId,
                encryptedContent: Data(),
                contentType: envelope.contentType.asMessageContentType ?? .file,
                deliveryStatus: .undecryptable,
                createdAt: min(envelope.createdAt, Date())
            )
            let inserted = try messageRepository.insertIfNotProcessed(
                placeholder,
                envelopeId: envelope.id,
                recipientUserId: myUserId,
                senderId: envelope.senderId
            )
            if inserted {
                incomingMessage = (conversation.id, placeholder)
            }
            return true
        } catch {
            logger.error("Couldn't record an undecryptable-message placeholder; leaving the envelope queued")
            return false
        }
    }

    private func resolveConversation(
        with envelope: EnvelopeDTO,
        plaintextPeerId: String,
        myUserId: String
    ) async throws -> Conversation {
        if let existing = try conversationRepository.findDirectConversation(
            ownerUserId: myUserId, userA: myUserId, userB: plaintextPeerId
        ) {
            return existing
        }

        let participants = [myUserId, plaintextPeerId]
        let conversation = Conversation(
            id: Conversation.deterministicId(participantIds: participants),
            ownerUserId: myUserId,
            participantIds: participants,
            isGroup: false,
            createdAt: min(envelope.createdAt, Date()),
            relationshipState: .invitedByThem,
            inviteSentAt: min(envelope.createdAt, Date())
        )
        try conversationRepository.upsert(conversation)
        return conversation
    }

    private func persistSessionState(for peerId: String, ownerUserId: String) throws {
        guard let encrypted = try cryptoService.exportEncryptedState(for: peerId) else { return }
        try sessionRepository.upsert(ownerUserId: ownerUserId, otherUserId: peerId, encryptedState: encrypted)
    }

    // MARK: Display

    func textContent(for message: Message) -> TextPayload? {
        guard message.contentType == .text, !message.isUndecryptable,
              let data = try? cryptoService.decryptFromStorage(message.encryptedContent)
        else { return nil }
        return TextPayload.decode(data)
    }

    func mediaDisplayMetadata(for message: Message) -> MediaDisplayMetadata? {
        guard message.carriesMediaPayload, !message.isUndecryptable else { return nil }
        guard let payloadData = try? cryptoService.decryptFromStorage(message.encryptedContent),
              let payload = try? MediaEncryptionService.decodeValidated(payloadData) else {
            return nil
        }
        return MediaDisplayMetadata(
            mediaType: payload.mediaType,
            duration: payload.duration,
            waveform: payload.waveform
        )
    }

    func displayText(for message: Message) -> String {
        if message.isUndecryptable {
            return "⚠️ This message couldn't be decrypted"
        }
        guard let data = try? cryptoService.decryptFromStorage(message.encryptedContent) else {
            return "🔒 Locked — unlock SecureHyperChat to read this message"
        }
        guard let payload = TextPayload.decode(data) else {
            return "⚠️ Message content is malformed"
        }
        return payload.text
    }

    func previewText(for message: Message) -> String {
        if message.isUndecryptable {
            return "⚠️ Couldn't be decrypted"
        }
        switch message.contentType {
        case .text:
            return displayText(for: message)
        case .image:
            return "📷 Photo"
        case .video:
            return "🎥 Video"
        case .file:
            return mediaDisplayMetadata(for: message)?.mediaType == .audio ? "🎤 Voice message" : "📎 File"
        }
    }

    func mediaData(for message: Message) async throws -> Data {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }
        let payload = try cryptoService.decryptFromStorage(message.encryptedContent)
        return try await mediaEncryptionService.decryptMedia(
            fromMessagePayload: payload,
            ownerUserId: myUserId
        )
    }

    func plaintext(for message: Message) -> String {
        displayText(for: message)
    }
}
