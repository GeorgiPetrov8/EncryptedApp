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

/// Orchestrates everything needed to send and receive end-to-end encrypted
/// messages: starting new sessions via X3DH, running the Double Ratchet,
/// persisting history (encrypted at rest), and listening for incoming envelopes.
@MainActor
final class MessagingService: ObservableObject {
    @Published private(set) var incomingMessage: (conversationId: String, message: Message)?
    @Published private(set) var identityAlert: IdentityError?
    @Published private(set) var lastReceiveError: String?

    /// FIX (Bug #25): observable connection state.
    ///
    /// `startListening` began with `guard let myUserId = ... else { return }` and gave
    /// no indication when that guard fired. The app looked healthy while silently
    /// receiving nothing.
    @Published private(set) var isListening = false
    /// FIX (Bug #12): true while the backfill sync is draining the queue.
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
        self.authService = authService
        self.syncCursors = syncCursors
    }

    /// Starts receiving. Driven by `AppContainer`'s subscription to the active
    /// account (Bug #25) rather than being called by hand from three places.
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

            // FIX (Bug #12): drain the durable queue *before* subscribing.
            //
            // Anything sent while this device wasn't listening only exists in the
            // server-side queue. Subscribing first would leave those messages
            // permanently unseen; the overlap between backfill and live stream is
            // harmless because Bug #8's dedup makes redelivery idempotent.
            await self.backfillPendingEnvelopes(myUserId: myUserId)

            for await envelope in self.webSocketService.events(for: myUserId) {
                do {
                    try await self.handleIncoming(envelope)
                    try? await self.apiClient.acknowledge(userId: myUserId, envelopeIds: [envelope.id])
                } catch {
                    await self.handleReceiveFailure(error, envelope: envelope, myUserId: myUserId)
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
            for envelope in page.envelopes {
                do {
                    try await handleIncoming(envelope)
                    delivered.append(envelope.id)
                } catch {
                    await handleReceiveFailure(error, envelope: envelope, myUserId: myUserId)
                    // Still acknowledge: the placeholder is persisted, so redelivering
                    // would only reproduce the same failure.
                    delivered.append(envelope.id)
                }
            }

            // Advance the cursor only after the batch is durably stored, so a crash
            // mid-sync resumes from the same point instead of skipping messages.
            syncCursors.advance(to: page.cursor, for: myUserId)
            try? await apiClient.acknowledge(userId: myUserId, envelopeIds: delivered)
            logger.info("Backfilled \(page.envelopes.count, privacy: .public) envelopes")
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

    /// FIX (Bug #11): guarantees a named `User` row exists for a peer.
    ///
    /// `startConversation` fetched a bundle and created the conversation but never
    /// called `userRepository.upsert`, and `resolveConversation` had only a
    /// `senderId`. The list read from `users` and fell back to "Unknown" every time.
    ///
    /// Order of preference: the name we were handed (handshake or bundle), then a
    /// directory lookup, then nothing — the caller renders a shortened id.
    @discardableResult
    private func ensureContact(userId: String, username: String?) async -> User? {
        if let existing = try? userRepository.fetch(id: userId) {
            // Backfill a placeholder name once the real one becomes available.
            if let username, existing.username != username {
                try? userRepository.updateUsername(userId: userId, username: username)
                return try? userRepository.fetch(id: userId)
            }
            return existing
        }

        if let username {
            try? userRepository.upsertContactPlaceholder(userId: userId, username: username)
            return try? userRepository.fetch(id: userId)
        }

        // Fallback: ask the directory. Pinning happens through the normal path, so
        // this only fills in display data.
        guard let bundle = try? await apiClient.fetchPreKeyBundle(forUserId: userId) else { return nil }
        try? pinOrVerifyIdentity(
            userId: bundle.userId,
            username: bundle.username,
            agreementKey: bundle.identityAgreementKey,
            signingKey: bundle.identitySigningKey
        )
        return try? userRepository.fetch(id: userId)
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
            username: bundle.username,
            agreementKey: bundle.identityAgreementKey,
            signingKey: bundle.identitySigningKey
        )
        // FIX (Bug #11): cache the contact so the list can name them immediately,
        // before any message has been exchanged.
        await ensureContact(userId: bundle.userId, username: bundle.username)

        if let existing = try conversationRepository.findDirectConversation(
            ownerUserId: myUserId, userA: myUserId, userB: bundle.userId
        ) {
            return existing
        }

        // FIX (Bug #14): deterministic id, so the peer's independently-created
        // conversation is the same conversation rather than a second one.
        let participants = [myUserId, bundle.userId]
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

    /// FIX (Bug #13): media send path with the ordering corrected.
    ///
    /// Encrypt and upload first, then write the message and the media row together in
    /// one transaction, then transmit. The media row can only be written once its
    /// parent message exists, which is exactly what the old flow got backwards.
    func sendMedia(
        rawData: Data,
        thumbnail: Data?,
        mediaType: MediaType,
        in conversation: Conversation,
        using mediaService: MediaEncryptionService
    ) async throws {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }

        let prepared = try await mediaService.prepareForSending(
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
        // Message row first, attachment second, one transaction (Bug #13).
        try messageRepository.insert(message, media: media)

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
                        username: bundle.username,
                        agreementKey: bundle.identityAgreementKey,
                        signingKey: bundle.identitySigningKey
                    )
                    await ensureContact(userId: peerId, username: bundle.username)

                    let result = try X3DH.initiate(myIdentity: identity, bundle: bundle)
                    let session = try DoubleRatchetSession(
                        initiatorRootKey: result.rootKey,
                        peerSignedPreKeyPublic: try CurveKeyHelper.publicKey(from: bundle.signedPreKey)
                    )
                    cryptoService.setSession(session, for: peerId)

                    handshake = HandshakeInitPayload(
                        identityAgreementKey: identity.agreementPublicKey.rawRepresentation,
                        identitySigningKey: identity.signingPublicKey.rawRepresentation,
                        // FIX (Bug #11): carry our name so the responder can label the
                        // conversation without a directory round trip.
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
            try messageRepository.updateDeliveryStatus(messageId: localMessageId, status: .sent)
        } catch {
            try messageRepository.updateDeliveryStatus(messageId: localMessageId, status: .failed)
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

        // FIX (Bug #11): make sure the sender has a named row before the list refreshes.
        await ensureContact(userId: envelope.senderId, username: envelope.handshake?.senderUsername)

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

    /// Logs the failure and leaves a visible marker in the conversation (Bug #9).
    private func handleReceiveFailure(_ error: Error, envelope: EnvelopeDTO, myUserId: String) async {
        // Never log plaintext or key material — only routing metadata.
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

    /// FIX (Bug #14): the conversation id is derived, not taken from the envelope.
    ///
    /// Trusting `envelope.conversationId` was half of the split-history problem: the
    /// sender's locally-generated UUID became a second conversation on the receiving
    /// side whenever the receiver had already created their own.
    ///
    /// For 1:1 chats both sides can compute the same id from the participants, so the
    /// envelope's value is only used as a diagnostic signal.
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

    /// FIX (Bug #18): the single place that decides what a message looks like in a
    /// one-line summary.
    ///
    /// `ConversationListViewModel` called `plaintext(for:)` unconditionally, so for a
    /// media message it rendered the raw `MediaKeyPayload` JSON — which contains the
    /// base64 per-file AES key. That put key material into a `String`, into the chat
    /// list, and therefore into screenshots and the app-switcher snapshot.
    ///
    /// Media types never reach the decryption branch here, so the payload cannot be
    /// stringified by accident again.
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

    /// Retained for source compatibility with existing callers.
    func plaintext(for message: Message) -> String {
        displayText(for: message)
    }
}
