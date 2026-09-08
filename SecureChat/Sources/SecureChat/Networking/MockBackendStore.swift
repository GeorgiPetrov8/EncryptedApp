import Foundation

/// Simulates a server. Deliberately holds only what a real zero-knowledge
/// server would ever see: public key bundles and ciphertext envelopes.
actor MockBackendStore {
    static let shared = MockBackendStore()

    /// Owns a mutable pool of one-time prekeys (Bug #1) and a mutable signed
    /// prekey so rotation is visible to peers (Bug #7).
    private struct StoredBundle {
        let userId: String
        let username: String
        let identityAgreementKey: Data
        let identitySigningKey: Data
        var signedPreKeyId: UInt32
        var signedPreKey: Data
        var signedPreKeySignature: Data
        var oneTimePreKeys: [OneTimePreKeyPublic]

        init(upload: PreKeyBundleUpload) {
            userId = upload.userId
            username = upload.username
            identityAgreementKey = upload.identityAgreementKey
            identitySigningKey = upload.identitySigningKey
            signedPreKeyId = upload.signedPreKeyId
            signedPreKey = upload.signedPreKey
            signedPreKeySignature = upload.signedPreKeySignature
            oneTimePreKeys = upload.oneTimePreKeys
        }

        mutating func issue() -> PreKeyBundle {
            let otk = oneTimePreKeys.isEmpty ? nil : oneTimePreKeys.removeFirst()
            return PreKeyBundle(
                userId: userId,
                username: username,
                identityAgreementKey: identityAgreementKey,
                identitySigningKey: identitySigningKey,
                signedPreKeyId: signedPreKeyId,
                signedPreKey: signedPreKey,
                signedPreKeySignature: signedPreKeySignature,
                oneTimePreKeyId: otk?.id,
                oneTimePreKey: otk?.publicKey
            )
        }
    }

    /// FIX (Bug #12): the durable per-recipient queue that was missing.
    ///
    /// `sequence` is a server-assigned monotonic counter. Clients resume from it
    /// rather than from `createdAt`, which is sender-supplied and can collide.
    private struct QueuedEnvelope {
        let sequence: Int
        let envelope: EnvelopeDTO
    }

    private var bundlesByUserId: [String: StoredBundle] = [:]
    private var userIdByUsername: [String: String] = [:]
    private var envelopesByConversation: [String: [EnvelopeDTO]] = [:]
    private var pendingByRecipient: [String: [QueuedEnvelope]] = [:]
    private var nextSequence = 1
    private var mediaBlobs: [String: Data] = [:]
    private var listeners: [String: AsyncStream<EnvelopeDTO>.Continuation] = [:]

    func register(username: String, bundle: PreKeyBundleUpload) throws -> AuthToken {
        guard userIdByUsername[username] == nil else { throw APIError.usernameTaken }
        userIdByUsername[username] = bundle.userId
        bundlesByUserId[bundle.userId] = StoredBundle(upload: bundle)
        return AuthToken(userId: bundle.userId, token: UUID().uuidString)
    }

    func login(username: String) throws -> AuthToken {
        guard let userId = userIdByUsername[username] else { throw APIError.userNotFound }
        return AuthToken(userId: userId, token: UUID().uuidString)
    }

    func replenishOneTimePreKeys(userId: String, keys: [OneTimePreKeyPublic]) throws {
        guard var stored = bundlesByUserId[userId] else { throw APIError.userNotFound }
        let existingIds = Set(stored.oneTimePreKeys.map(\.id))
        stored.oneTimePreKeys.append(contentsOf: keys.filter { !existingIds.contains($0.id) })
        bundlesByUserId[userId] = stored
    }

    /// Replaces the published signed prekey (Bug #7). Older ids are no longer
    /// advertised, but the *client* keeps their private halves through the grace
    /// period so in-flight handshakes still resolve.
    func publishSignedPreKey(_ upload: SignedPreKeyUpload) throws {
        guard var stored = bundlesByUserId[upload.userId] else { throw APIError.userNotFound }
        stored.signedPreKeyId = upload.signedPreKeyId
        stored.signedPreKey = upload.signedPreKey
        stored.signedPreKeySignature = upload.signedPreKeySignature
        bundlesByUserId[upload.userId] = stored
    }

    func remainingOneTimePreKeyCount(userId: String) -> Int {
        bundlesByUserId[userId]?.oneTimePreKeys.count ?? 0
    }

    func bundle(forUsername username: String) throws -> PreKeyBundle {
        guard let userId = userIdByUsername[username] else { throw APIError.userNotFound }
        return try bundle(forUserId: userId)
    }

    func bundle(forUserId userId: String) throws -> PreKeyBundle {
        guard var stored = bundlesByUserId[userId] else { throw APIError.userNotFound }
        let issued = stored.issue()
        bundlesByUserId[userId] = stored // persist the pop
        return issued
    }

    /// Test-only seam for Bug #2: simulate a hostile server swapping identity keys.
    func overrideIdentityForTesting(userId: String, agreementKey: Data, signingKey: Data) throws {
        guard let stored = bundlesByUserId[userId] else { throw APIError.userNotFound }
        let replacement = PreKeyBundleUpload(
            userId: stored.userId,
            username: stored.username,
            identityAgreementKey: agreementKey,
            identitySigningKey: signingKey,
            signedPreKeyId: stored.signedPreKeyId,
            signedPreKey: stored.signedPreKey,
            signedPreKeySignature: stored.signedPreKeySignature,
            oneTimePreKeys: stored.oneTimePreKeys
        )
        bundlesByUserId[userId] = StoredBundle(upload: replacement)
    }

    /// FIX (Bug #12): every envelope is queued durably *and* streamed.
    ///
    /// Previously the yield was the only delivery path, so anything sent while the
    /// recipient wasn't subscribed vanished from their perspective.
    func send(_ envelope: EnvelopeDTO) {
        envelopesByConversation[envelope.conversationId, default: []].append(envelope)

        let queued = QueuedEnvelope(sequence: nextSequence, envelope: envelope)
        nextSequence += 1
        pendingByRecipient[envelope.recipientId, default: []].append(queued)

        listeners[envelope.recipientId]?.yield(envelope)
    }

    func envelopes(conversationId: String) -> [EnvelopeDTO] {
        envelopesByConversation[conversationId] ?? []
    }

    /// FIX (Bug #12): ordered backfill from a cursor.
    func pendingEnvelopes(userId: String, since cursor: Int) -> PendingEnvelopesPage {
        let queue = (pendingByRecipient[userId] ?? []).filter { $0.sequence > cursor }
        let ordered = queue.sorted { $0.sequence < $1.sequence }
        return PendingEnvelopesPage(
            envelopes: ordered.map(\.envelope),
            cursor: ordered.last?.sequence ?? cursor
        )
    }

    /// FIX (Bug #12): drops envelopes the client has durably stored.
    func acknowledge(userId: String, envelopeIds: [String]) {
        guard let queue = pendingByRecipient[userId] else { return }
        let acknowledged = Set(envelopeIds)
        pendingByRecipient[userId] = queue.filter { !acknowledged.contains($0.envelope.id) }
    }

    func pendingCount(userId: String) -> Int {
        pendingByRecipient[userId]?.count ?? 0
    }

    func subscribe(userId: String) -> AsyncStream<EnvelopeDTO> {
        AsyncStream { continuation in
            listeners[userId] = continuation
        }
    }

    func unsubscribe(userId: String) {
        listeners[userId]?.finish()
        listeners[userId] = nil
    }

    func storeMedia(id: String, data: Data) {
        mediaBlobs[id] = data
    }

    func media(id: String) throws -> Data {
        guard let data = mediaBlobs[id] else { throw APIError.mediaNotFound }
        return data
    }
}
