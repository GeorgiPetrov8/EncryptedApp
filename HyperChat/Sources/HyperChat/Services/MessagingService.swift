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

    private let cryptoService: CryptoService
    private let apiClient: APIClientProtocol
    private let webSocketService: WebSocketServiceProtocol
    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let sessionRepository: SessionRepository
    private let userRepository: UserRepository
    private let authService: AuthService
    private let syncCursors: SyncCursorStore

    /// Stored dependency because the receive path needs it too, and
    /// `handleIncoming` is driven by a background stream, not a caller.
    private let mediaEncryptionService: MediaEncryptionService

    /// Same reasoning as `mediaEncryptionService` — `.notePad` envelopes are
    /// routed to it from `handleIncoming`.
    private let notePadService: NotePadService

    /// FIX (Pack 8, Critical #1): handshakes retained until the peer replies.
    private let pendingHandshakes = PendingHandshakeStore()

    /// FIX (Pack 8): serialises sends per peer.
    ///
    /// Two first sends to the same peer at once (a double tap, the alarm word
    /// and a notepad edit together) used to both find `session == nil`, both
    /// run X3DH, and the second session overwrote the first — so the peer
    /// could never decrypt one of the two messages. Chaining each send behind
    /// the previous one for the same peer means only the first performs the
    /// handshake; the second finds the session already in place.
    private var sendChains: [String: Task<Void, Never>] = [:]

    /// FIX (Pack 8): was `com.securechat`, so these logs didn't show up when
    /// filtering Console by the `com.HyperChat` subsystem every other service uses.
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

    /// Driven by `AppContainer`'s subscription to the active account (Bug #25).
    func startListening() {
        guard let myUserId = authService.currentUserId else {
            logger.error("startListening called with no active account; listener not started")
            isListening = false
            return
        }
        listenerTask?.cancel()
        isListening = true

        // FIX (Pack 8): subscribe *before* backfilling.
        //
        // The stream used to be created only after the backfill finished, so
        // anything sent in between arrived through neither path and waited
        // for the next launch. Creating the stream first opens the connection
        // immediately and `AsyncStream` buffers envelopes while the backfill
        // runs. The overlap is harmless: Bug #8's dedup makes redelivery
        // idempotent.
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
                    let recorded = await handleReceiveFailure(error, envelope: envelope, myUserId: myUserId)
                    if recorded {
                        delivered.append(envelope.id)
                    } else {
                        allDurable = false
                        logger.error("Envelope \(envelope.id, privacy: .public) left queued; nothing durable was written")
                    }
                }
            }

            // Advance only if every envelope is durably accounted for.
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

    // MARK: Starting a conversation

    func startConversation(withUsername username: String) async throws -> Conversation {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }

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

    // MARK: Sending — shared transport core

    /// Runs `operation` after any send already in flight to the same peer.
    private func serialized<T>(peerId: String, _ operation: @escaping () async throws -> T) async throws -> T {
        let previous = sendChains[peerId]
        let task = Task { () async throws -> T in
            _ = await previous?.value
            return try await operation()
        }
        sendChains[peerId] = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Everything a chat message and a notepad sync both need: make sure a
    /// session exists, ratchet-encrypt, persist the session, and send.
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

        /// Non-nil only when *this* call created the session.
        var createdHandshake: HandshakeInitPayload?

        if cryptoService.session(for: peerId) == nil {
            if let record = try sessionRepository.fetch(ownerUserId: myUserId, otherUserId: peerId) {
                try cryptoService.restoreSession(encryptedState: record.encryptedState, for: peerId)
            } else {
                // The one place a one-time prekey *should* be consumed.
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

        // FIX (Pack 8, Critical #1): re-attach a handshake the peer hasn't
        // confirmed yet, even on an envelope that would otherwise go out as
        // plain `.ratchet`. A recipient that already has the session ignores
        // it; one that missed the first envelope can still derive the session.
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
            // Retained *before* the send, so a lost response still leaves us
            // able to re-attach rather than re-handshake.
            pendingHandshakes.store(createdHandshake, ownerUserId: myUserId, peerId: peerId)
        }

        do {
            try await apiClient.sendMessage(envelope)
        } catch {
            if createdHandshake != nil {
                // FIX (Pack 8, Critical #1): this send created the session and
                // its handshake never arrived. Leaving the session in place
                // meant every later send went out as a `.ratchet` envelope with
                // no handshake, which the peer can never decrypt — and because
                // conversation ids are deterministic, "start a new
                // conversation" reused the same orphaned session. Roll back so
                // the next attempt performs a fresh X3DH.
                rollbackHandshakeSession(peerId: peerId, ownerUserId: myUserId)
                pendingHandshakes.clear(ownerUserId: myUserId, peerId: peerId)
            }
            throw error
        }
    }

    /// Removes a just-created session after its handshake failed to transmit —
    /// from memory (what the next send sees) and from disk (what a relaunch
    /// restores). Leaving either behind reproduces the bug.
    private func rollbackHandshakeSession(peerId: String, ownerUserId: String) {
        cryptoService.clearSession(for: peerId)
        do {
            try sessionRepository.delete(ownerUserId: ownerUserId, otherUserId: peerId)
        } catch {
            logger.error("Couldn't delete the rolled-back session row for \(peerId, privacy: .public)")
        }
    }

    /// Drops every retained handshake for an account — call on account deletion.
    func clearPendingHandshakes(ownerUserId: String) {
        pendingHandshakes.clearAll(ownerUserId: ownerUserId)
    }

    // MARK: Sending — chat messages

    func sendText(_ text: String, in conversation: Conversation) async throws {
        try await send(plaintext: Data(text.utf8), contentType: .text, in: conversation)
    }

    /// Media send path (Bug #13): encrypt and upload first, then write the
    /// message and the media row together, then transmit.
    func sendMedia(
        rawData: Data,
        thumbnail: Data?,
        mediaType: MediaType,
        duration: TimeInterval? = nil,
        waveform: [Float]? = nil,
        in conversation: Conversation
    ) async throws {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }

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
        case .image:
            contentType = .image

        case .video:
            contentType = .video

        case .audio:
            contentType = .file

        case .document:
            contentType = .file
        }

        try await send(
            plaintext: prepared.messagePayload,
            contentType: contentType,
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
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }

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
            // FIX (Pack 8): `try?`, not `try`. If marking the row failed threw,
            // it replaced the real send error — the UI then showed a database
            // error instead of "couldn't send", and the retry logic in
            // `ChatViewModel` lost the information it decides on.
            try? messageRepository.updateDeliveryStatus(messageId: localMessageId, ownerUserId: myUserId, status: .failed)
            throw error
        }
    }

    // MARK: Sending — shared notepad

    /// The transport half of `NotePadService.apply`. Does not touch
    /// `MessageRepository` — a notepad sync has no chat-bubble representation.
    func sendNotePadOperation(_ operation: NotePadOperation, in conversation: Conversation) async throws {
        let plaintext = try JSONEncoder().encode(operation)
        try await transmitEnvelope(
            id: UUID().uuidString,
            plaintext: plaintext,
            contentType: .notePad,
            in: conversation,
            createdAt: operation.updatedAt
        )
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

        // FIX (Pack 8, Critical #1): their message decrypted, so they have the
        // session — stop re-attaching our handshake.
        pendingHandshakes.clear(ownerUserId: myUserId, peerId: envelope.senderId)

        await ensureContact(
            ownerUserId: myUserId,
            userId: envelope.senderId,
            username: envelope.handshake?.senderUsername
        )

        let conversation = try await resolveConversation(
            with: envelope, plaintextPeerId: envelope.senderId, myUserId: myUserId
        )

        // Notepad routing: no `Message` row, same replay protection.
        if envelope.contentType == .notePad {
            let recorded = try messageRepository.markEnvelopeProcessed(
                envelopeId: envelope.id, recipientUserId: myUserId, senderId: envelope.senderId
            )
            guard recorded else {
                logger.debug("Ignoring already-processed notepad envelope")
                return
            }
            guard let operation = try? JSONDecoder().decode(NotePadOperation.self, from: plaintext) else {
                logger.error("Notepad envelope payload didn't decode; dropping this edit")
                return
            }
            notePadService.applyRemoteOperation(operation, conversationId: conversation.id, ownerUserId: myUserId)
            return
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
    }

    /// Builds the recipient's `MediaItem` for an inbound media message.
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
            logger.error(
                "Inbound media payload didn't decode; storing the message without a media row"
            )
            return nil
        }
    }

    /// Logs the failure and leaves a visible marker in the conversation (Bug #9).
    /// - Returns: whether something durable was written.
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

        lastReceiveError = (error as? LocalizedError)?.errorDescription
            ?? ReceiveError.decryptionFailed.localizedDescription

        // A failed `.notePad` envelope has no timeline to show a placeholder in.
        guard envelope.contentType != .notePad else { return false }

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

    func mediaDisplayMetadata(for message: Message) -> MediaDisplayMetadata? {
        guard message.carriesMediaPayload else {
            return nil
        }

        guard !message.isUndecryptable else {
            return nil
        }

        guard let payloadData = try? cryptoService.decryptFromStorage(
            message.encryptedContent
        ) else {
            return nil
        }

        guard let payload = try? JSONDecoder().decode(
            MediaKeyPayload.self,
            from: payloadData
        ) else {
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

    /// The single place that decides what a message looks like as a
    /// one-line summary (Bug #18).
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
