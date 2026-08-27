import Foundation

/// Simulates a server. Deliberately holds only what a real zero-knowledge
/// server would ever see: public key bundles and ciphertext envelopes.
actor MockBackendStore {
    static let shared = MockBackendStore()

    /// FIX (Bug #1): owns a mutable pool of one-time prekeys.
    /// FIX (Bug #7): the signed prekey is mutable too, so rotation is visible to peers.
    private struct StoredBundle {
        let userId: String
        let identityAgreementKey: Data
        let identitySigningKey: Data
        var signedPreKeyId: UInt32
        var signedPreKey: Data
        var signedPreKeySignature: Data
        var oneTimePreKeys: [OneTimePreKeyPublic]

        init(upload: PreKeyBundleUpload) {
            userId = upload.userId
            identityAgreementKey = upload.identityAgreementKey
            identitySigningKey = upload.identitySigningKey
            signedPreKeyId = upload.signedPreKeyId
            signedPreKey = upload.signedPreKey
            signedPreKeySignature = upload.signedPreKeySignature
            oneTimePreKeys = upload.oneTimePreKeys
        }

        /// Pops one prekey and returns the bundle to hand out. An empty pool yields
        /// `nil`, which both `X3DH.initiate` and `X3DH.respond` handle by skipping dh4.
        mutating func issue() -> PreKeyBundle {
            let otk = oneTimePreKeys.isEmpty ? nil : oneTimePreKeys.removeFirst()
            return PreKeyBundle(
                userId: userId,
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

    private var bundlesByUserId: [String: StoredBundle] = [:]
    private var userIdByUsername: [String: String] = [:]
    private var envelopesByConversation: [String: [EnvelopeDTO]] = [:]
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

    /// FIX (Bug #7): replaces the published signed prekey. Older ids are simply no
    /// longer advertised — the *client* keeps their private halves through the grace
    /// period so handshakes already in flight still resolve.
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
            identityAgreementKey: agreementKey,
            identitySigningKey: signingKey,
            signedPreKeyId: stored.signedPreKeyId,
            signedPreKey: stored.signedPreKey,
            signedPreKeySignature: stored.signedPreKeySignature,
            oneTimePreKeys: stored.oneTimePreKeys
        )
        bundlesByUserId[userId] = StoredBundle(upload: replacement)
    }

    func send(_ envelope: EnvelopeDTO) {
        envelopesByConversation[envelope.conversationId, default: []].append(envelope)
        listeners[envelope.recipientId]?.yield(envelope)
    }

    func envelopes(conversationId: String) -> [EnvelopeDTO] {
        envelopesByConversation[conversationId] ?? []
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
