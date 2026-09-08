import Foundation

// MARK: - Public key material published to the server (X3DH)

/// A single published one-time prekey (Bug #1).
struct OneTimePreKeyPublic: Codable, Equatable {
    let id: UInt32
    let publicKey: Data
}

/// A rotated signed prekey, published on its own (Bug #7).
struct SignedPreKeyUpload: Codable, Equatable {
    let userId: String
    let signedPreKeyId: UInt32
    let signedPreKey: Data
    let signedPreKeySignature: Data
}

/// What the client uploads at registration (Bug #1).
struct PreKeyBundleUpload: Codable, Equatable {
    let userId: String
    /// FIX (Bug #11): the directory entry now carries the username.
    ///
    /// Without it the server had no way to answer "who is user X?", so
    /// `resolveConversation` — which only ever sees a `senderId` — could not name
    /// the peer and the whole list fell back to "Unknown".
    let username: String
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
    /// FIX (Bug #11): carried through so both the outbound and inbound paths can
    /// name the peer from a single fetch.
    let username: String
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
    /// The initiator's signing key, so the responder can pin the full identity (Bug #2).
    let identitySigningKey: Data
    /// FIX (Bug #11): lets the responder name the initiator without a server round
    /// trip, which matters because the responder may be offline-backfilling.
    let senderUsername: String?
    let ephemeralPublicKey: Data
    /// The responder must resolve *this* id, not its current key (Bug #7).
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

/// FIX (Bug #12): the result of a backfill sync.
///
/// `cursor` is the point to resume from next time. It is returned by the server
/// rather than derived from `createdAt` on the client, because `createdAt` is
/// sender-supplied and two envelopes can share a timestamp — resuming from a
/// timestamp would either re-deliver or skip messages at the boundary.
struct PendingEnvelopesPage: Codable, Equatable {
    let envelopes: [EnvelopeDTO]
    let cursor: Int
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
