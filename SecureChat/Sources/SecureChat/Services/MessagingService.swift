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

/// FIX (Bug #9): reasons an inbound envelope couldn't be turned into a message.
/// Previously every one of these was erased by `try?`.
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

/// Orchestrates everything needed to send and receive end-to-end encrypted
/// messages: starting new sessions via X3DH, running the Double Ratchet,
/// persisting history (encrypted at rest), and listening for incoming envelopes.
@MainActor
final class MessagingService: ObservableObject {
    @Published private(set) var incomingMessage: (conversationId: String, message: Message)?
    @Published private(set) var identityAlert: IdentityError?
    /// FIX (Bug #9): the most recent receive failure, surfaced in `ChatView`.
    @Published private(set) var lastReceiveError: String?

    private let cryptoService: CryptoService
    private let apiClient: APIClientProtocol
    private let webSocketService: WebSocketServiceProtocol
    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let sessionRepository: SessionRepository
    private let userRepository: UserRepository
    private let authService: AuthService

    private let logger = Logger(subsystem: "com.securechat", category: "messaging")
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
        authService: AuthService
    ) {
        self.cryptoService = cryptoService
        self.apiClient = apiClient
        self.webSocketService = webSocketService
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.sessionRepository = sessionRepository
        self.userRepository = userRepository
        self.authService = authService
    }

    /// Call once after login/registration to start receiving in real time.
    func startListening() {
        guard let myUserId = authService.currentUserId else {
            logger.error("startListening called with no active account")
            return
        }
        listenerTask?.cancel()
        listenerTask = Task {
            for await envelope in webSocketService.events(for: myUserId) {
                // FIX (Bug #9): was `try? await handleIncoming(envelope)`.
                do {
                    try await handleIncoming(envelope)
                } catch {
                    await handleReceiveFailure(error, envelope: envelope, myUserId: myUserId)
                }
            }
        }
        Task { await performStartupMaintenance() }
    }

    func stopListening() {
        listenerTask?.cancel()
        if let myUserId = authService.currentUserId {
            webSocketService.disconnect(userId: myUserId)
        }
    }

    func clearReceiveError() {
        lastReceiveError = nil
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

    /// FIX (Bug #7): rotates the signed prekey and — crucially — publishes it.
    ///
    /// Local rotation alone would be invisible: the server kept serving the original
    /// signed prekey, so every initiator would keep handshaking against a key we
    /// intended to retire.
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

    /// FIX (Bug #1): publishes a fresh batch when the local pool runs low.
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

    // MARK: Identity pinning (Bug #2)

    private func pinOrVerifyIdentity(
        userId: String,
        username: String?,
        agreementKey: Data,
        signingKey: Data
    ) throws {
        let result = try userRepository.pinOrCompareIdentity(
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

    func acknowledgeIdentityChange(userId: String) throws {
        try userRepository.acknowledgeIdentityChange(userId: userId)
        identityAlert = nil
    }

    func setVerified(_ verified: Bool, userId: String) throws {
        try userRepository.setVerified(verified, userId: userId)
    }

    func safetyNumber(forPeerId peerId: String) throws -> String? {
        guard let identity = cryptoService.identity,
              let peer = try userRepository.fetch(id: peerId),
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
              let peer = try userRepository.fetch(id: peerId),
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
        return try userRepository.fetch(id: peerId)
    }

    // MARK: Starting a conversation

    func startConversation(withUsername username: String) async throws -> Conversation {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }

        let bundle = try await apiClient.fetchPreKeyBundle(forUsername: username)

        try pinOrVerifyIdentity(
            userId: bundle.userId,
            username: username,
            agreementKey: bundle.identityAgreementKey,
            signingKey: bundle.identitySigningKey
        )

        if let existing = try conversationRepository.findDirectConversation(
            ownerUserId: myUserId, userA: myUserId, userB: bundle.userId
        ) {
            return existing
        }

        let conversation = Conversation(
            id: UUID().uuidString,
            ownerUserId: myUserId,
            participantIds: [myUserId, bundle.userId],
            isGroup: false,
            createdAt: Date()
        )
        try conversationRepository.upsert(conversation)
        return conversation
    }

    // MARK: Sending

    func sendText(_ text: String, in conversation: Conversation) async throws {
        try await send(plaintext: Data(text.utf8), contentType: .text, in: conversation)
    }

    func send(plaintext: Data, contentType: MessageContentType, in conversation: Conversation) async throws {
        guard let myUserId = authService.currentUserId,
              let identity = cryptoService.identity else { throw APIError.notAuthenticated }
        guard let peerId = conversation.otherParticipant(myUserId: myUserId) else { throw APIError.userNotFound }

        if let peer = try userRepository.fetch(id: peerId), peer.hasUnacknowledgedIdentityChange {
            throw IdentityError.identityChangeUnacknowledged(userId: peerId)
        }

        let localMessageId = UUID().uuidString
        let storedCiphertext = try cryptoService.encryptForStorage(plaintext)

        var message = Message(
            id: localMessageId,
            ownerUserId: myUserId,
            conversationId: conversation.id,
            senderId: myUserId,
            encryptedContent: storedCiphertext,
            contentType: contentType,
            deliveryStatus: .sending,
            createdAt: Date()
        )
        try messageRepository.insert(message)

        do {
            var handshake: HandshakeInitPayload?
            var kind: EnvelopeKind = .ratchet

            if cryptoService.session(for: peerId) == nil {
                if let record = try sessionRepository.fetch(ownerUserId: myUserId, otherUserId: peerId) {
                    try cryptoService.restoreSession(encryptedState: record.encryptedState, for: peerId)
                } else {
                    let bundle = try await apiClient.fetchPreKeyBundle(forUserId: peerId)

                    try pinOrVerifyIdentity(
                        userId: peerId,
                        username: nil,
                        agreementKey: bundle.identityAgreementKey,
                        signingKey: bundle.identitySigningKey
                    )

                    let result = try X3DH.initiate(myIdentity: identity, bundle: bundle)
                    let session = try DoubleRatchetSession(
                        initiatorRootKey: result.rootKey,
                        peerSignedPreKeyPublic: try CurveKeyHelper.publicKey(from: bundle.signedPreKey)
                    )
                    cryptoService.setSession(session, for: peerId)

                    handshake = HandshakeInitPayload(
                        identityAgreementKey: identity.agreementPublicKey.rawRepresentation,
                        identitySigningKey: identity.signingPublicKey.rawRepresentation,
                        ephemeralPublicKey: result.ephemeralPublicKey.rawRepresentation,
                        usedSignedPreKeyId: bundle.signedPreKeyId,
                        usedOneTimePreKeyId: result.usedOneTimePreKeyId
                    )
                    kind = .handshake
                }
            }

            guard let session = cryptoService.session(for: peerId) else { throw CryptoError.sessionNotReady }
            let ratchetMessage = try session.encrypt(plaintext: plaintext)
            try persistSessionState(for: peerId, ownerUserId: myUserId)

            let envelope = EnvelopeDTO(
                id: localMessageId,
                conversationId: conversation.id,
                senderId: myUserId,
                recipientId: peerId,
                kind: kind,
                handshake: handshake,
                ratchetMessage: try ratchetMessage.serialized(),
                contentType: contentType,
                createdAt: message.createdAt
            )
            try await apiClient.sendMessage(envelope)

            message.deliveryStatus = .sent
            try messageRepository.updateDeliveryStatus(messageId: localMessageId, status: .sent)
        } catch {
            try messageRepository.updateDeliveryStatus(messageId: localMessageId, status: .failed)
            throw error
        }
    }

    // MARK: Receiving

    private func handleIncoming(_ envelope: EnvelopeDTO) async throws {
        // FIX (Bug #9): these were silent `return`s. The middle one — a ratchet
        // message with no session — is precisely the case worth seeing, and it
        // vanished without a trace.
        guard let myUserId = authService.currentUserId else { throw ReceiveError.notAuthenticated }
        guard let identity = cryptoService.identity else { throw ReceiveError.notAuthenticated }

        // FIX (Bug #8): check *before* touching the ratchet.
        //
        // The ticket assumed a duplicate would be caught by the primary-key conflict
        // on insert. It is — but only after `decrypt` has already rotated
        // `receivingChainKey` and `persistSessionState` has written the mutated state
        // to disk. The damage is done before the conflict is raised.
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
                    userId: envelope.senderId,
                    username: nil,
                    agreementKey: handshake.identityAgreementKey,
                    signingKey: handshake.identitySigningKey
                )

                // FIX (Bug #7): resolve the signed prekey the initiator actually used.
                //
                // The old `requireSignedPreKey()` returned whatever the current key
                // happened to be and ignored `usedSignedPreKeyId` entirely. That was
                // harmless only because the key never rotated; with rotation it would
                // silently derive a different root key on each side.
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
        // Atomic since Bug #3: a rejected message rolls the session back cleanly.
        let plaintext = try session.decrypt(ratchetMessage)
        try persistSessionState(for: envelope.senderId, ownerUserId: myUserId)

        let conversation = try await resolveConversation(
            with: envelope, plaintextPeerId: envelope.senderId, myUserId: myUserId
        )
        let storedCiphertext = try cryptoService.encryptForStorage(plaintext)

        let message = Message(
            id: envelope.id,
            ownerUserId: myUserId,
            conversationId: conversation.id,
            senderId: envelope.senderId,
            encryptedContent: storedCiphertext,
            contentType: envelope.contentType,
            deliveryStatus: .delivered,
            createdAt: envelope.createdAt
        )

        // FIX (Bug #8): message row and dedup marker in one transaction.
        let inserted = try messageRepository.insertIfNotProcessed(
            message,
            envelopeId: envelope.id,
            recipientUserId: myUserId,
            senderId: envelope.senderId
        )
        guard inserted else {
            logger.debug("Envelope was processed concurrently; dropping duplicate")
            return
        }

        incomingMessage = (conversation.id, message)
    }

    /// FIX (Bug #9): logs the failure and leaves a visible marker in the conversation.
    private func handleReceiveFailure(_ error: Error, envelope: EnvelopeDTO, myUserId: String) async {
        // Never log plaintext or key material — only the routing metadata.
        logger.error("""
            Failed to process envelope \(envelope.id, privacy: .public) \
            from \(envelope.senderId, privacy: .public): \
            \(String(describing: type(of: error)), privacy: .public)
            """)

        if let identityError = error as? IdentityError {
            identityAlert = identityError
            lastReceiveError = identityError.localizedDescription
            return
        }

        lastReceiveError = (error as? LocalizedError)?.errorDescription
            ?? ReceiveError.decryptionFailed.localizedDescription

        // Leave a placeholder so the gap in the conversation is visible rather than
        // the message simply never appearing.
        await insertUndecryptablePlaceholder(for: envelope, myUserId: myUserId)
    }

    private func insertUndecryptablePlaceholder(for envelope: EnvelopeDTO, myUserId: String) async {
        do {
            guard let conversation = try? await resolveConversation(
                with: envelope, plaintextPeerId: envelope.senderId, myUserId: myUserId
            ) else { return }

            let placeholder = Message(
                id: envelope.id,
                ownerUserId: myUserId,
                conversationId: conversation.id,
                senderId: envelope.senderId,
                encryptedContent: Data(), // nothing recoverable to store
                contentType: envelope.contentType,
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
        } catch {
            logger.error("Couldn't record an undecryptable-message placeholder")
        }
    }

    private func resolveConversation(
        with envelope: EnvelopeDTO,
        plaintextPeerId: String,
        myUserId: String
    ) async throws -> Conversation {
        if let existing = try conversationRepository.fetch(id: envelope.conversationId, ownerUserId: myUserId) {
            return existing
        }
        let conversation = Conversation(
            id: envelope.conversationId,
            ownerUserId: myUserId,
            participantIds: [myUserId, plaintextPeerId],
            isGroup: false,
            createdAt: envelope.createdAt
        )
        try conversationRepository.upsert(conversation)
        return conversation
    }

    private func persistSessionState(for peerId: String, ownerUserId: String) throws {
        guard let encrypted = try cryptoService.exportEncryptedState(for: peerId) else { return }
        try sessionRepository.upsert(ownerUserId: ownerUserId, otherUserId: peerId, encryptedState: encrypted)
    }

    // MARK: Display

    /// Decrypts a stored message's local-storage ciphertext for display.
    ///
    /// FIX (Bug #9): the three failure modes are now distinguishable. Previously all
    /// of them rendered the identical string "🔒 Unable to decrypt message", which
    /// meant the symptom of Bug #10 (storage key overwritten by a second
    /// registration) looked exactly like the symptom of a tampered envelope —
    /// making either one impossible to diagnose from the UI.
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

    /// Retained for source compatibility with existing callers.
    func plaintext(for message: Message) -> String {
        displayText(for: message)
    }
}
