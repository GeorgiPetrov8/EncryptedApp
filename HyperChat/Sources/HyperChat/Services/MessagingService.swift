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

/// Orchestrates everything needed to send and receive end-to-end encrypted messages.
@MainActor
final class MessagingService: ObservableObject {
    @Published private(set) var incomingMessage: (conversationId: String, message: Message)?
    @Published private(set) var identityAlert: IdentityError?
    @Published private(set) var lastReceiveError: String?
    @Published private(set) var isListening = false
    @Published private(set) var isSyncing = false

    private let cryptoService: CryptoService
    private let apiClient: APIClientProtocol
    private let webSocketService: WebSocketServiceProtocol
    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let sessionRepository: SessionRepository
    private let userRepository: UserRepository
    private let authService: AuthService
    private let syncCursors: SyncCursorStore

    /// FIX: now a stored dependency rather than a parameter on `sendMedia` only.
    ///
    /// The receive path needs it too — to turn an inbound media payload into the
    /// recipient's own `MediaItem` — and there is no sensible way to thread a service
    /// through `handleIncoming`, which is driven by a background stream rather than by
    /// a caller. `MediaEncryptionService` depends on nothing that depends on this
    /// type, so holding it here introduces no cycle; `AppContainer` just has to build
    /// it first.
    private let mediaEncryptionService: MediaEncryptionService

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
        self.authService = authService
        self.syncCursors = syncCursors
    }

    /// Driven by `AppContainer`'s subscription to the active account (Bug #25).
    func startListening() {
        guard let myUserId = authService.currentUserId else {
            logger.error("startListening called with no active account; listener not started")
            isListening = false
            return
        }
        listenerTask?.cancel()
        isListening = true

        listenerTask = Task { [weak self] in
            guard let self else { return }

            // Drain the durable queue before subscribing (Bug #12). The overlap with
            // the live stream is harmless because Bug #8's dedup makes redelivery
            // idempotent.
            await self.backfillPendingEnvelopes(myUserId: myUserId)

            for await envelope in self.webSocketService.events(for: myUserId) {
                do {
                    try await self.handleIncoming(envelope)
                    try? await self.apiClient.acknowledge(userId: myUserId, envelopeIds: [envelope.id])
                } catch {
                    let recorded = await self.handleReceiveFailure(error, envelope: envelope, myUserId: myUserId)
                    // Only release the server's copy once something durable exists
                    // locally (see `backfillPendingEnvelopes`).
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

    /// Replays everything queued since this account's cursor, in server order.
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
                    // Acknowledging unconditionally made failures unrecoverable: the
                    // envelope was deleted server-side even when nothing had been
                    // stored locally.
                    let recorded = await handleReceiveFailure(error, envelope: envelope, myUserId: myUserId)
                    if recorded {
                        delivered.append(envelope.id)
                    } else {
                        allDurable = false
                        logger.error("Envelope \(envelope.id, privacy: .public) left queued; nothing durable was written")
                    }
                }
            }

            // The cursor only advances if every envelope in the batch is durably
            // accounted for; otherwise the next sync would skip the gap permanently.
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

    /// Rotates the signed prekey and publishes it (Bug #7).
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

    /// Publishes a fresh batch when the local pool runs low (Bug #1).
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

    /// Guarantees a named `User` row exists for a peer (Bug #11).
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

        // Directory lookup, not a prekey bundle fetch: the bundle endpoint pops a
        // one-time prekey on every call, so answering "what is this contact called?"
        // used to permanently consume a key reserved for establishing a session.
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

    // MARK: Starting a conversation

    func startConversation(withUsername username: String) async throws -> Conversation {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }

        // Resolve the peer without consuming a prekey; the bundle is fetched later, in
        // `send`, at the point a session is actually established.
        let entry = try await apiClient.fetchDirectoryEntry(username: username)

        try pinOrVerifyIdentity(
            ownerUserId: myUserId,
            userId: entry.userId,
            username: entry.username,
            agreementKey: entry.identityAgreementKey,
            signingKey: entry.identitySigningKey
        )
        await ensureContact(ownerUserId: myUserId, userId: entry.userId, username: entry.username)

        if let existing = try conversationRepository.findDirectConversation(
            ownerUserId: myUserId, userA: myUserId, userB: entry.userId
        ) {
            return existing
        }

        // Deterministic id, so the peer's independently-created conversation is the
        // same conversation rather than a second one (Bug #14).
        let participants = [myUserId, entry.userId]
        let conversation = Conversation(
            id: Conversation.deterministicId(participantIds: participants),
            ownerUserId: myUserId,
            participantIds: participants,
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

    /// Media send path with the ordering corrected (Bug #13): encrypt and upload
    /// first, then write the message and the media row together in one transaction,
    /// then transmit.
    ///
    /// FIX: the `using mediaService:` parameter is gone — the service is now held by
    /// this type, because the receive path needs it too.
    func sendMedia(
        rawData: Data,
        thumbnail: Data?,
        mediaType: MediaType,
        in conversation: Conversation
    ) async throws {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }

        let prepared = try await mediaEncryptionService.prepareForSending(
            rawData: rawData,
            thumbnail: thumbnail,
            mediaType: mediaType,
            ownerUserId: myUserId
        )

        try await send(
            plaintext: prepared.messagePayload,
            contentType: mediaType == .image ? .image : .video,
            in: conversation,
            media: prepared.pendingMediaItem
        )
    }

    func send(
        plaintext: Data,
        contentType: MessageContentType,
        in conversation: Conversation,
        media: MediaItem? = nil
    ) async throws {
        guard let myUserId = authService.currentUserId,
              let identity = cryptoService.identity else { throw APIError.notAuthenticated }
        guard let peerId = conversation.otherParticipant(myUserId: myUserId) else { throw APIError.userNotFound }

        if let peer = try userRepository.fetch(ownerUserId: myUserId, id: peerId),
           peer.hasUnacknowledgedIdentityChange {
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
        try messageRepository.insert(message, media: media)

        do {
            var handshake: HandshakeInitPayload?
            var kind: EnvelopeKind = .ratchet

            if cryptoService.session(for: peerId) == nil {
                if let record = try sessionRepository.fetch(ownerUserId: myUserId, otherUserId: peerId) {
                    try cryptoService.restoreSession(encryptedState: record.encryptedState, for: peerId)
                } else {
                    // The one place a prekey *should* be consumed: an actual handshake.
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

                    handshake = HandshakeInitPayload(
                        identityAgreementKey: identity.agreementPublicKey.rawRepresentation,
                        identitySigningKey: identity.signingPublicKey.rawRepresentation,
                        senderUsername: authService.currentUsername,
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
            try messageRepository.updateDeliveryStatus(
                messageId: localMessageId, ownerUserId: myUserId, status: .sent
            )
        } catch {
            try messageRepository.updateDeliveryStatus(
                messageId: localMessageId, ownerUserId: myUserId, status: .failed
            )
            throw error
        }
    }

    // MARK: Receiving

    private func handleIncoming(_ envelope: EnvelopeDTO) async throws {
        guard let myUserId = authService.currentUserId else { throw ReceiveError.notAuthenticated }
        guard let identity = cryptoService.identity else { throw ReceiveError.notAuthenticated }

        // Dedup before touching the ratchet (Bug #8).
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

                // Resolve the signed prekey the initiator actually used (Bug #7).
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

        await ensureContact(
            ownerUserId: myUserId,
            userId: envelope.senderId,
            username: envelope.handshake?.senderUsername
        )

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

        // FIX: the recipient now gets their own media row.
        //
        // This was the missing half of the media flow: `MediaItem` was only ever
        // constructed on the sending side, so a received photo left the recipient's
        // cached blob unreferenced. `exclusivelyOwnedPaths` would then conclude the
        // sender was its only owner and unlink the shared file.
        let media = makeMediaItemIfNeeded(
            plaintext: plaintext,
            envelope: envelope,
            conversationId: conversation.id,
            myUserId: myUserId
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
    }

    /// Builds the recipient's `MediaItem` for an inbound media message.
    ///
    /// Returns `nil` for text, and also for a media message whose payload won't decode
    /// — a malformed attachment shouldn't cost the user the message itself, which is
    /// still readable as "📷 Photo" in the list and can still be retried. The failure
    /// is logged rather than thrown for that reason.
    private func makeMediaItemIfNeeded(
        plaintext: Data,
        envelope: EnvelopeDTO,
        conversationId: String,
        myUserId: String
    ) -> MediaItem? {
        let mediaType: MediaType
        switch envelope.contentType {
        case .image: mediaType = .image
        case .video: mediaType = .video
        case .text, .file: return nil
        }

        do {
            return try mediaEncryptionService.makeReceivedMediaItem(
                payloadData: plaintext,
                messageId: envelope.id,
                ownerUserId: myUserId,
                mediaType: mediaType,
                createdAt: envelope.createdAt
            )
        } catch {
            logger.error("Inbound media payload didn't decode; storing the message without a media row")
            return nil
        }
    }

    /// Logs the failure and leaves a visible marker in the conversation (Bug #9).
    ///
    /// - Returns: whether something durable was written, so the caller can decide
    ///   whether the server may release its copy.
    @discardableResult
    private func handleReceiveFailure(_ error: Error, envelope: EnvelopeDTO, myUserId: String) async -> Bool {
        // Never log plaintext or key material — only routing metadata.
        logger.error("""
            Failed to process envelope \(envelope.id, privacy: .public) \
            from \(envelope.senderId, privacy: .public): \
            \(String(describing: type(of: error)), privacy: .public)
            """)

        if let identityError = error as? IdentityError {
            identityAlert = identityError
            lastReceiveError = identityError.localizedDescription
            // Deliberately not durable: once the user accepts the new keys the
            // envelope should be reprocessed, so it must stay on the server.
            return false
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
                encryptedContent: Data(), // nothing recoverable to store
                contentType: envelope.contentType,
                deliveryStatus: .undecryptable,
                createdAt: envelope.createdAt
            )
            // No media row: the payload never decrypted, so there is no `mediaId` to
            // claim ownership of.
            let inserted = try messageRepository.insertIfNotProcessed(
                placeholder,
                envelopeId: envelope.id,
                recipientUserId: myUserId,
                senderId: envelope.senderId
            )
            if inserted {
                incomingMessage = (conversation.id, placeholder)
            }
            // Already-processed counts as durable: a row exists either way.
            return true
        } catch {
            logger.error("Couldn't record an undecryptable-message placeholder; leaving the envelope queued")
            return false
        }
    }

    /// The conversation id is derived, not taken from the envelope (Bug #14).
    private func resolveConversation(
        with envelope: EnvelopeDTO,
        plaintextPeerId: String,
        myUserId: String
    ) async throws -> Conversation {
        let participants = [myUserId, plaintextPeerId]
        let canonicalId = Conversation.deterministicId(participantIds: participants)

        if canonicalId != envelope.conversationId {
            logger.debug("Envelope carried a non-canonical conversation id; using the derived one")
        }

        if let existing = try conversationRepository.fetch(id: canonicalId, ownerUserId: myUserId) {
            return existing
        }

        // A conversation created before this change may still exist under the old
        // random id — adopt it rather than starting a parallel history.
        if let legacy = try conversationRepository.findDirectConversation(
            ownerUserId: myUserId, userA: myUserId, userB: plaintextPeerId
        ) {
            return legacy
        }

        let conversation = Conversation(
            id: canonicalId,
            ownerUserId: myUserId,
            participantIds: participants,
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

    /// Decrypts a stored message's local-storage ciphertext for display (Bug #9).
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

    /// The single place that decides what a message looks like as a one-line summary
    /// (Bug #18). Media types never reach the decryption branch, so the key-bearing
    /// payload cannot be stringified by accident.
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
            return "📎 File"
        }
    }

    /// Decrypts a media message's bytes for display, in memory only.
    ///
    /// Passes `ownerUserId` so the provisional `fileSize` recorded at receive time is
    /// backfilled once the blob is actually downloaded.
    func mediaData(for message: Message) async throws -> Data {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }
        let payload = try cryptoService.decryptFromStorage(message.encryptedContent)
        return try await mediaEncryptionService.decryptMedia(
            fromMessagePayload: payload,
            ownerUserId: myUserId
        )
    }

    /// Retained for source compatibility with existing callers.
    func plaintext(for message: Message) -> String {
        displayText(for: message)
    }
}
