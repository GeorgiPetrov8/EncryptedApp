import Foundation

// MARK: - Public key material published to the server (X3DH)

/// A single published one-time prekey. FIX (Bug #1): the server tracks prekeys
/// individually so it can hand a *different* one to each peer.
struct OneTimePreKeyPublic: Codable, Equatable {
    let id: UInt32
    let publicKey: Data
}

/// FIX (Bug #7): a rotated signed prekey, published on its own.
///
/// Rotation was previously impossible to complete end-to-end: `APIClientProtocol`
/// only had `register`, and `MockBackendStore.bundlesByUserId` was written solely by
/// `register()`. A client could generate a new signed prekey locally, but no peer
/// would ever see it, so every initiator kept handshaking against the original key.
struct SignedPreKeyUpload: Codable, Equatable {
    let userId: String
    let signedPreKeyId: UInt32
    let signedPreKey: Data
    let signedPreKeySignature: Data
}

/// FIX (Bug #1): what the client *uploads* at registration (and tops up later).
struct PreKeyBundleUpload: Codable, Equatable {
    let userId: String
    let identityAgreementKey: Data     // raw X25519 public key
    let identitySigningKey: Data       // raw Ed25519 public key
    let signedPreKeyId: UInt32
    let signedPreKey: Data             // raw X25519 public key
    let signedPreKeySignature: Data
    let oneTimePreKeys: [OneTimePreKeyPublic]
}

/// What the server hands out when a peer wants to start a session with a
/// user. All fields are public keys / signatures — nothing here lets the
/// server decrypt anything (zero-knowledge principle from the spec).
struct PreKeyBundle: Codable, Equatable {
    let userId: String
    let identityAgreementKey: Data
    let identitySigningKey: Data
    let signedPreKeyId: UInt32
    let signedPreKey: Data
    let signedPreKeySignature: Data
    let oneTimePreKeyId: UInt32?
    let oneTimePreKey: Data?
}

// MARK: - X3DH handshake payload

/// Sent alongside the very first message in a new conversation so the
/// responder can derive the same shared secret the initiator did.
struct HandshakeInitPayload: Codable, Equatable {
    let identityAgreementKey: Data
    /// FIX (Bug #2): the responder needs the initiator's signing key too, so it can
    /// pin the full identity without trusting a separate server lookup.
    let identitySigningKey: Data
    let ephemeralPublicKey: Data
    /// FIX (Bug #7): the responder must resolve *this* id, not its current key.
    let usedSignedPreKeyId: UInt32
    let usedOneTimePreKeyId: UInt32?
}

enum EnvelopeKind: String, Codable {
    case handshake
    case ratchet
}

/// The only thing that ever crosses the network.
struct EnvelopeDTO: Codable, Equatable {
    let id: String
    let conversationId: String
    let senderId: String
    let recipientId: String
    let kind: EnvelopeKind
    let handshake: HandshakeInitPayload?
    let ratchetMessage: Data
    let contentType: MessageContentType
    let createdAt: Date
}

struct RegisterRequest: Codable {
    let username: String
    let bundle: PreKeyBundleUpload
}

struct AuthToken: Codable, Equatable {
    let userId: String
    let token: String
}

struct MediaUploadResult: Codable, Equatable {
    let mediaId: String
}
