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
    /// incoming message (queued flush, implicit acceptance, an edit).
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

    /// After restoring a backup on a new device: start a fresh session with
    /// every accepted contact.
    ///
    /// The restored device has the right identity but no ratchet state (old
    /// sessions are deliberately not restored — see `exportKeyMaterial`). An
    /// empty delivery receipt is the cheapest thing to send: it forces a new
    /// X3DH handshake, the contact's app rebuilds its side from it (see
    /// `handleIncoming`), and applying an empty receipt changes nothing.
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
            try? userRepository.upsertContactPlaceholder(ownerUserId: ownerUserId, userId: userId, username: username)
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

    /// Sends a text message, optionally as a reply. The default argument keeps
    /// existing `sendText(_:in:)` call sites (e.g. the alarm word) working.
    func sendText(_ text: String, replyTo: ReplyReference? = nil, in conversation: Conversation) async throws {
        let payload = TextPayload(text: text, replyTo: replyTo)
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

        // While our invitation is pending the message waits locally.
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

    // MARK: Editing and deleting

    func canEdit(_ message: Message) -> Bool {
        guard let me = authService.currentUserId else { return false }
        return message.senderId == me
            && message.contentType == .text
            && !message.isUndecryptable
            && message.deliveryStatus != .failed
            && Date().timeIntervalSince(message.createdAt) <= MessageEditPolicy.window
    }

    /// Changes the text of one of our own messages and tells the peer.
    ///
    /// A reply keeps its quote. A message still queued behind an invitation is
    /// only updated locally — it goes out with the new text when it's flushed.
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

    /// Removes a message from this device only.
    func deleteMessageLocally(messageId: String, conversationId: String) throws {
        guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
        try messageRepository.delete(messageId: messageId, ownerUserId: me)
        conversationChanged.send(conversationId)
    }

    // MARK: Sending — control messages

    func sendNotePadOperation(_ operation: NotePadOperation, in conversation: Conversation) async throws {
        try await sendControlPayload(operation, kind: .notePad, in: conversation, createdAt: operation.updatedAt)
    }

    /// Everything except the invitation itself requires an accepted conversation.
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

    /// Builds our side of a session from a peer's X3DH handshake.
    private func respondToHandshake(
        _ handshake: HandshakeInitPayload,
        senderId: String,
        myUserId: String,
        identity: IdentityKeyPair
    ) async throws -> DoubleRatchetSession {
        try pinOrVerifyIdentity(
            ownerUserId: myUserId,
            userId: senderId,
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
        await replenishOneTimePreKeysIfNeeded()
        return DoubleRatchetSession(responderRootKey: rootKey, mySignedPreKeyPair: mySignedPreKey.privateKey)
    }

    /// Decrypts an envelope, establishing or rebuilding the session as needed.
    ///
    /// New: if we already have a session but the message doesn't decrypt with
    /// it, AND the envelope carries a handshake, the peer has started over —
    /// typically because they restored their account on a new phone. We rebuild
    /// our side from their handshake instead of failing forever. If the rebuild
    /// doesn't decrypt either, the old session is put back untouched.
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
        // Set only after a successful decrypt, so a bad handshake can't leave
        // an unusable session behind.
        cryptoService.setSession(fresh, for: senderId)
        return plaintext
    }

    private func handleIncoming(_ envelope: EnvelopeDTO) async throws {
        guard let myUserId = authService.currentUserId else { throw ReceiveError.notAuthenticated }
        guard let identity = cryptoService.identity else { throw ReceiveError.notAuthenticated }

        if try messageRepository.isEnvelopeProcessed(
            envelopeId: envelope.id, recipientUserId: myUserId, senderId: envelope.senderId
        ) {
            logger.debug("Ignoring already-processed envelope")
            return
        }

        let plaintext = try await decryptEnvelope(envelope, myUserId: myUserId, identity: identity)
        try persistSessionState(for: envelope.senderId, ownerUserId: myUserId)
        pendingHandshakes.clear(ownerUserId: myUserId, peerId: envelope.senderId)

        await ensureContact(
            ownerUserId: myUserId,
            userId: envelope.senderId,
            username: envelope.handshake?.senderUsername
        )

        // Control traffic other than an invitation never creates a conversation.
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
            try handleControlMessage(envelope, plaintext: plaintext, conversation: conversation, myUserId: myUserId)
            return
        }

        // A chat message where we invited them means they accepted.
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

        let message = Message(
            id: envelope.id,
            ownerUserId: myUserId,
            conversationId: conversation.id,
            senderId: envelope.senderId,
            encryptedContent: try cryptoService.encryptForStorage(plaintext),
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
        guard recorded else {
            logger.debug("Ignoring already-processed control envelope")
            return
        }

        let decoder = JSONDecoder()
        switch envelope.contentType {
        case .notePad:
            guard let operation = try? decoder.decode(NotePadOperation.self, from: plaintext) else { return }
            notePadService.applyRemoteOperation(operation, conversationId: conversation.id, ownerUserId: myUserId)

        case .receipt:
            guard let payload = try? decoder.decode(ReceiptPayload.self, from: plaintext) else { return }
            receiptHandler?(payload, conversation)

        case .profile:
            guard let payload = try? decoder.decode(ProfilePayload.self, from: plaintext) else { return }
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

        case .text, .image, .video, .file:
            break
        }
    }

    /// Applies a peer's edit — only to their own text message in this
    /// conversation, and only within the edit window.
    private func applyRemoteEdit(_ edit: EditPayload, from senderId: String, conversation: Conversation, myUserId: String) throws {
        let text = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let original = try messageRepository.fetch(messageId: edit.messageId, ownerUserId: myUserId),
              original.senderId == senderId,
              original.conversationId == conversation.id,
              original.contentType == .text,
              !original.isUndecryptable,
              edit.editedAt.timeIntervalSince(original.createdAt) <= MessageEditPolicy.window + MessageEditPolicy.receiveGrace
        else {
            logger.info("Ignored an edit that didn't match a message the sender can edit")
            return
        }

        let payload = TextPayload(text: text, replyTo: textContent(for: original)?.replyTo)
        try messageRepository.updateContent(
            messageId: original.id,
            ownerUserId: myUserId,
            encryptedContent: try cryptoService.encryptForStorage(try payload.encoded()),
            editedAt: edit.editedAt
        )
        conversationChanged.send(conversation.id)
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
        logger.error("Failed to process envelope \(envelope.id, privacy: .public) from \(envelope.senderId, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")

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

    /// The decoded text (and quote) of a text message, or nil for other types.
    func textContent(for message: Message) -> TextPayload? {
        guard message.contentType == .text, !message.isUndecryptable,
              let data = try? cryptoService.decryptFromStorage(message.encryptedContent)
        else { return nil }
        return TextPayload.decode(data)
    }

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
