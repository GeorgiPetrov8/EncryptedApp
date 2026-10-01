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

    var errorDescription: String? {
        switch self {
        case .noSessionForRatchetMessage:
            return "A message arrived for a conversation this device has no session for. Ask your contact to start a new conversation."
        case .notAuthenticated:
            return "A message arrived while no account was active."
        case .decryptionFailed:
            return "A message couldn't be decrypted. It may have been tampered with in transit."
        }
    }
}

struct MediaDisplayMetadata {
    let mediaType: MediaType
    let duration: TimeInterval?
    let waveform: [Float]?
}

/// Orchestrates everything needed to send and receive end-to-end encrypted messages.
@MainActor
final class MessagingService: ObservableObject {
    @Published private(set) var incomingMessage: (conversationId: String, message: Message)?
    @Published private(set) var identityAlert: IdentityError?
    @Published private(set) var lastReceiveError: String?
    @Published private(set) var isListening = false
    @Published private(set) var isSyncing = false

    /// Emits a conversation id when its messages changed locally without an
    /// incoming message — e.g. queued messages were flushed after an
    /// invitation was accepted, or a chat became accepted implicitly.
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

    private let pendingHandshakes = PendingHandshakeStore()
    private var sendChains: [String: Task<Void, Never>] = [:]

    // MARK: Control-message handlers (set by AppContainer)

    private var deliveryHandler: ((Message, Conversation) -> Void)?
    private var receiptHandler: ((ReceiptPayload, Conversation) -> Void)?
    private var profileHandler: ((ProfilePayload, Conversation, String) -> Void)?
    private var inviteHandler: ((InvitePayload, Conversation, String) -> Void)?
    private var callHandler: ((CallSignal, Conversation, String) -> Void)?

    private let logger = Logger(subsystem: "com.HyperChat", category: "messaging")
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
        syncCursors: SyncCursorStore = SyncCursorStore()
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

        // Subscribe *before* backfilling, so nothing sent in between is missed.
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
                        logger.error("Envelope \(envelope.id, privacy: .public) left queued; nothing durable was written")
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
            logger.info("Rotated signed prekey to id \(rotated.id, privacy: .public)")
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
            logger.info("Replenished \(fresh.count, privacy: .public) one-time prekeys")
        } catch {
            logger.error("One-time prekey replenish failed")
        }
    }

    // MARK: Identity pinning (Bug #2) and contact caching (Bug #11)

    private func pinOrVerifyIdentity(
        ownerUserId: String,
        userId: String,
        username: String?,
        agreementKey: Data,
        signingKey: Data
    ) throws {
        let result = try userRepository.pinOrCompareIdentity(
            ownerUserId: ownerUserId,
            userId: userId,
            username: username,
            agreementKey: agreementKey,
            signingKey: signingKey
        )
        switch result {
        case .pinned, .matches:
            return
        case .changed:
            logger.fault("Identity key mismatch for \(userId, privacy: .public)")
            throw IdentityError.identityChanged(userId: userId)
        case .changePending:
            throw IdentityError.identityChangeUnacknowledged(userId: userId)
        }
    }

    @discardableResult
    private func ensureContact(ownerUserId: String, userId: String, username: String?) async -> User? {
        if let existing = try? userRepository.fetch(ownerUserId: ownerUserId, id: userId) {
            if let username, existing.username != username {
                try? userRepository.updateUsername(ownerUserId: ownerUserId, userId: userId, username: username)
                return try? userRepository.fetch(ownerUserId: ownerUserId, id: userId)
            }
            return existing
        }

        if let username {
            try? userRepository.upsertContactPlaceholder(
                ownerUserId: ownerUserId, userId: userId, username: username
            )
            return try? userRepository.fetch(ownerUserId: ownerUserId, id: userId)
        }

        guard let entry = try? await apiClient.fetchDirectoryEntry(userId: userId) else { return nil }
        try? pinOrVerifyIdentity(
            ownerUserId: ownerUserId,
            userId: entry.userId,
            username: entry.username,
            agreementKey: entry.identityAgreementKey,
            signingKey: entry.identitySigningKey
        )
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

    // NOTE (invitations): `startConversation(withUsername:)` is gone on purpose.
    // It created an `accepted` conversation and let you write to anyone
    // directly — exactly what invitations replace. New chats go through
    // `InvitationService.invite(username:note:)`.

    // MARK: Invitation gate

    /// The conversation's *current* state from the database. The value passed
    /// in by a view may be stale (e.g. accepted a moment ago by the other side).
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

                try pinOrVerifyIdentity(
                    ownerUserId: myUserId,
                    userId: peerId,
                    username: bundle.username,
                    agreementKey: bundle.identityAgreementKey,
                    signingKey: bundle.identitySigningKey
                )
                await ensureContact(ownerUserId: myUserId, userId: peerId, username: bundle.username)

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
            logger.error("Couldn't delete the rolled-back session row for \(peerId, privacy: .public)")
        }
    }

    func clearPendingHandshakes(ownerUserId: String) {
        pendingHandshakes.clearAll(ownerUserId: ownerUserId)
    }

    // MARK: Sending — chat messages

    func sendText(_ text: String, in conversation: Conversation) async throws {
        try await send(plaintext: Data(text.utf8), contentType: .text, in: conversation)
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

        // Checked before uploading, so a blocked send doesn't upload a blob.
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

    /// You can compose in an accepted chat and in one *you* started (queued);
    /// not in a request you haven't accepted, nor after a decline.
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

        // FIX (invitations): while our invitation is pending, the message is
        // stored with a clock and *not* transmitted. `flushQueuedMessages`
        // sends it once they accept.
        guard state == .accepted else { return }

        do {
            try await transmitEnvelope(
                id: localMessageId,
                plaintext: plaintext,
                contentType: contentType.asEnvelopePayloadKind,
                in: conversation,
                createdAt: createdAt
            )
            try messageRepository.updateDeliveryStatus(messageId: localMessageId, ownerUserId: myUserId, status: .sent)
        } catch {
            try? messageRepository.updateDeliveryStatus(messageId: localMessageId, ownerUserId: myUserId, status: .failed)
            throw error
        }
    }

    /// Sends everything we composed while our invitation was pending.
    ///
    /// Each message keeps its original id, so a repeated flush (e.g. after a
    /// crash mid-flush) is deduplicated by the recipient's processed-envelope
    /// check instead of producing duplicates.
    func flushQueuedMessages(in conversation: Conversation) async {
        guard let myUserId = authService.currentUserId,
              relationshipState(of: conversation) == .accepted else { return }

        let queued = ((try? messageRepository.fetchMessages(
            conversationId: conversation.id, ownerUserId: myUserId
        )) ?? []).filter { $0.senderId == myUserId && $0.deliveryStatus == .sending }

        for message in queued {
            do {
                let plaintext = try cryptoService.decryptFromStorage(message.encryptedContent)
                try await transmitEnvelope(
                    id: message.id,
                    plaintext: plaintext,
                    contentType: message.contentType.asEnvelopePayloadKind,
                    in: conversation,
                    createdAt: message.createdAt
                )
                try? messageRepository.updateDeliveryStatus(messageId: message.id, ownerUserId: myUserId, status: .sent)
            } catch {
                try? messageRepository.updateDeliveryStatus(messageId: message.id, ownerUserId: myUserId, status: .failed)
                logger.error("Couldn't send a queued message after acceptance")
            }
        }
        conversationChanged.send(conversation.id)
    }

    // MARK: Sending — control messages

    func sendNotePadOperation(_ operation: NotePadOperation, in conversation: Conversation) async throws {
        try await sendControlPayload(operation, kind: .notePad, in: conversation, createdAt: operation.updatedAt)
    }

    /// One entry point for every payload that is not a chat bubble.
    ///
    /// FIX (invitations): everything except the invitation itself requires an
    /// accepted conversation — otherwise the shared pad, receipts, profile
    /// photos or a call would reach someone who never agreed to talk.
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

    private func handleIncoming(_ envelope: EnvelopeDTO) async throws {
        guard let myUserId = authService.currentUserId else { throw ReceiveError.notAuthenticated }
        guard let identity = cryptoService.identity else { throw ReceiveError.notAuthenticated }

        if try messageRepository.isEnvelopeProcessed(
            envelopeId: envelope.id, recipientUserId: myUserId, senderId: envelope.senderId
        ) {
            logger.debug("Ignoring already-processed envelope")
            return
        }

        if cryptoService.session(for: envelope.senderId) == nil {
            if let record = try sessionRepository.fetch(ownerUserId: myUserId, otherUserId: envelope.senderId) {
                try cryptoService.restoreSession(encryptedState: record.encryptedState, for: envelope.senderId)
            } else if envelope.kind == .handshake, let handshake = envelope.handshake {
                try pinOrVerifyIdentity(
                    ownerUserId: myUserId,
                    userId: envelope.senderId,
                    username: handshake.senderUsername,
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
                let session = DoubleRatchetSession(
                    responderRootKey: rootKey,
                    mySignedPreKeyPair: mySignedPreKey.privateKey
                )
                cryptoService.setSession(session, for: envelope.senderId)

                await replenishOneTimePreKeysIfNeeded()
            } else {
                throw ReceiveError.noSessionForRatchetMessage(senderId: envelope.senderId)
            }
        }

        guard let session = cryptoService.session(for: envelope.senderId) else {
            throw ReceiveError.noSessionForRatchetMessage(senderId: envelope.senderId)
        }

        let ratchetMessage = try RatchetMessage.deserialize(envelope.ratchetMessage)
        let plaintext = try session.decrypt(ratchetMessage)
        try persistSessionState(for: envelope.senderId, ownerUserId: myUserId)

        pendingHandshakes.clear(ownerUserId: myUserId, peerId: envelope.senderId)

        await ensureContact(
            ownerUserId: myUserId,
            userId: envelope.senderId,
            username: envelope.handshake?.senderUsername
        )

        // FIX (invitations): control traffic other than an invitation is never
        // allowed to *create* a conversation. A receipt, profile, pad edit or
        // call from someone we have no chat with has nothing to apply to.
        let isControl = envelope.contentType.isControlMessage
        if isControl && envelope.contentType != .invite {
            guard let existing = try conversationRepository.findDirectConversation(
                ownerUserId: myUserId, userA: myUserId, userB: envelope.senderId
            ) else {
                _ = try messageRepository.markEnvelopeProcessed(
                    envelopeId: envelope.id, recipientUserId: myUserId, senderId: envelope.senderId
                )
                logger.debug("Dropped control traffic from someone without a conversation")
                return
            }
            try handleControlMessage(envelope, plaintext: plaintext, conversation: existing, myUserId: myUserId)
            return
        }

        var conversation = try await resolveConversation(
            with: envelope, plaintextPeerId: envelope.senderId, myUserId: myUserId
        )

        if isControl {
            // Only `.invite` reaches here.
            try handleControlMessage(envelope, plaintext: plaintext, conversation: conversation, myUserId: myUserId)
            return
        }

        // FIX (invitations): a chat message on a conversation where *we*
        // invited them means they accepted — even if the explicit `.accept`
        // was lost or hasn't arrived yet. Treat it as acceptance and send what
        // we queued, instead of leaving both sides waiting on each other.
        if conversation.relationshipState == .invitedByMe {
            conversation.relationshipState = .accepted
            conversation.inviteRespondedAt = Date()
            try conversationRepository.upsert(conversation)
            let accepted = conversation
            Task { await self.flushQueuedMessages(in: accepted) }
            conversationChanged.send(conversation.id)
        }

        guard let messageContentType = envelope.contentType.asMessageContentType else {
            logger.fault("Envelope contentType had no MessageContentType mapping")
            return
        }

        let storedCiphertext = try cryptoService.encryptForStorage(plaintext)

        let message = Message(
            id: envelope.id,
            ownerUserId: myUserId,
            conversationId: conversation.id,
            senderId: envelope.senderId,
            encryptedContent: storedCiphertext,
            contentType: messageContentType,
            deliveryStatus: .delivered,
            createdAt: envelope.createdAt
        )

        let media = makeMediaItemIfNeeded(
            plaintext: plaintext,
            messageContentType: messageContentType,
            envelopeId: envelope.id,
            myUserId: myUserId,
            createdAt: envelope.createdAt
        )

        let inserted = try messageRepository.insertIfNotProcessed(
            message,
            media: media,
            envelopeId: envelope.id,
            recipientUserId: myUserId,
            senderId: envelope.senderId
        )
        guard inserted else {
            logger.debug("Envelope was processed concurrently; dropping duplicate")
            return
        }

        incomingMessage = (conversation.id, message)
        // Receipts are gated on acceptance inside `sendControlPayload`, so a
        // message request doesn't tell the sender it was delivered.
        deliveryHandler?(message, conversation)
    }

    /// Applies a decrypted control payload. Never creates a `Message` row, but
    /// gets the same replay protection as chat messages.
    private func handleControlMessage(
        _ envelope: EnvelopeDTO,
        plaintext: Data,
        conversation: Conversation,
        myUserId: String
    ) throws {
        let recorded = try messageRepository.markEnvelopeProcessed(
            envelopeId: envelope.id, recipientUserId: myUserId, senderId: envelope.senderId
        )
        guard recorded else {
            logger.debug("Ignoring already-processed control envelope")
            return
        }

        let decoder = JSONDecoder()
        switch envelope.contentType {
        case .notePad:
            guard let operation = try? decoder.decode(NotePadOperation.self, from: plaintext) else {
                logger.error("Notepad payload didn't decode; dropping this edit")
                return
            }
            notePadService.applyRemoteOperation(operation, conversationId: conversation.id, ownerUserId: myUserId)

        case .receipt:
            guard let payload = try? decoder.decode(ReceiptPayload.self, from: plaintext) else {
                logger.error("Receipt payload didn't decode")
                return
            }
            receiptHandler?(payload, conversation)

        case .profile:
            guard let payload = try? decoder.decode(ProfilePayload.self, from: plaintext) else {
                logger.error("Profile payload didn't decode")
                return
            }
            profileHandler?(payload, conversation, envelope.senderId)

        case .invite:
            guard let payload = try? decoder.decode(InvitePayload.self, from: plaintext) else {
                logger.error("Invitation payload didn't decode")
                return
            }
            inviteHandler?(payload, conversation, envelope.senderId)

        case .call:
            guard let signal = try? decoder.decode(CallSignal.self, from: plaintext) else {
                logger.error("Call signal didn't decode")
                return
            }
            callHandler?(signal, conversation, envelope.senderId)

        case .text, .image, .video, .file:
            break // unreachable: guarded by `isControlMessage`
        }
    }

    private func makeMediaItemIfNeeded(
        plaintext: Data,
        messageContentType: MessageContentType,
        envelopeId: String,
        myUserId: String,
        createdAt: Date
    ) -> MediaItem? {
        switch messageContentType {
        case .image, .video, .file:
            break
        case .text:
            return nil
        }

        do {
            return try mediaEncryptionService.makeReceivedMediaItem(
                payloadData: plaintext,
                messageId: envelopeId,
                ownerUserId: myUserId,
                createdAt: createdAt
            )
        } catch {
            logger.error("Inbound media payload didn't decode; storing the message without a media row")
            return nil
        }
    }

    @discardableResult
    private func handleReceiveFailure(_ error: Error, envelope: EnvelopeDTO, myUserId: String) async -> Bool {
        logger.error("""
            Failed to process envelope \(envelope.id, privacy: .public) \
            from \(envelope.senderId, privacy: .public): \
            \(String(describing: type(of: error)), privacy: .public)
            """)

        if let identityError = error as? IdentityError {
            identityAlert = identityError
            lastReceiveError = identityError.localizedDescription
            return false
        }

        // A failed control envelope has no timeline to show a placeholder in.
        // Mark it handled so it doesn't block the sync cursor forever.
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
                createdAt: envelope.createdAt
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

    /// Finds the conversation with this sender, or creates one.
    ///
    /// FIX (invitations): a conversation created by an *inbound* envelope starts
    /// as `invitedByThem`, not `accepted`. Someone you never accepted can't
    /// open a normal chat with you just by sending something — it lands in
    /// Invitations instead, and you decide.
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
            createdAt: envelope.createdAt,
            relationshipState: .invitedByThem,
            inviteSentAt: envelope.createdAt
        )
        try conversationRepository.upsert(conversation)
        return conversation
    }

    private func persistSessionState(for peerId: String, ownerUserId: String) throws {
        guard let encrypted = try cryptoService.exportEncryptedState(for: peerId) else { return }
        try sessionRepository.upsert(ownerUserId: ownerUserId, otherUserId: peerId, encryptedState: encrypted)
    }

    // MARK: Display

    func mediaDisplayMetadata(for message: Message) -> MediaDisplayMetadata? {
        guard message.carriesMediaPayload, !message.isUndecryptable else { return nil }
        guard let payloadData = try? cryptoService.decryptFromStorage(message.encryptedContent),
              let payload = try? JSONDecoder().decode(MediaKeyPayload.self, from: payloadData) else {
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
            return "🔒 Locked — this message belongs to a different account on this device"
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return "⚠️ Message content is malformed"
        }
        return text
    }

    func previewText(for message: Message) -> String {
        if message.isUndecryptable {
            return "⚠️ Couldn't be decrypted"
        }
        switch message.contentType {
        case .text: return displayText(for: message)
        case .image: return "📷 Photo"
        case .video: return "🎥 Video"
        case .file: return "📎 File"
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
