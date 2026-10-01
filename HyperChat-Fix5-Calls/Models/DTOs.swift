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
    let username: String
    let identityAgreementKey: Data     // raw X25519 public key
    let identitySigningKey: Data       // raw Ed25519 public key
    let signedPreKeyId: UInt32
    let signedPreKey: Data             // raw X25519 public key
    let signedPreKeySignature: Data
    let oneTimePreKeys: [OneTimePreKeyPublic]
}

/// What the server hands out when a peer wants to start a session.
struct PreKeyBundle: Codable, Equatable {
    let userId: String
    let username: String
    let identityAgreementKey: Data
    let identitySigningKey: Data
    let signedPreKeyId: UInt32
    let signedPreKey: Data
    let signedPreKeySignature: Data
    let oneTimePreKeyId: UInt32?
    let oneTimePreKey: Data?
}

/// The non-destructive directory lookup — never consumes a one-time prekey.
struct DirectoryEntry: Codable, Equatable {
    let userId: String
    let username: String
    let identityAgreementKey: Data
    let identitySigningKey: Data
}

// MARK: - X3DH handshake payload

struct HandshakeInitPayload: Codable, Equatable {
    let identityAgreementKey: Data
    let identitySigningKey: Data
    let senderUsername: String?
    let ephemeralPublicKey: Data
    let usedSignedPreKeyId: UInt32
    let usedOneTimePreKeyId: UInt32?
}

enum EnvelopeKind: String, Codable {
    case handshake
    case ratchet
}

/// What kind of plaintext an envelope's ciphertext decrypts to.
///
/// Deliberately separate from `MessageContentType`: control payloads never
/// become chat bubbles, so they don't belong in the type every bubble/preview
/// `switch` has to handle.
enum EnvelopePayloadKind: String, Codable, Equatable {
    case text
    case image
    case video
    case file
    /// A `NotePadOperation`.
    case notePad
    /// A `ReceiptPayload` — delivered/read acknowledgement.
    case receipt
    /// A `ProfilePayload` — display name and avatar.
    case profile
    /// An `InvitePayload` — contact request or its answer.
    case invite
    /// FIX (calls): a `CallSignal` — offer, answer, ICE candidate, end, update.
    /// Travels through the Double Ratchet like everything else, so the server
    /// can't read or swap the SDP (and with it the DTLS fingerprint).
    case call

    var asMessageContentType: MessageContentType? {
        switch self {
        case .text: return .text
        case .image: return .image
        case .video: return .video
        case .file: return .file
        case .notePad, .receipt, .profile, .invite, .call: return nil
        }
    }

    /// Control payloads are merged into local state and never rendered in
    /// the timeline.
    var isControlMessage: Bool {
        asMessageContentType == nil
    }
}

extension MessageContentType {
    var asEnvelopePayloadKind: EnvelopePayloadKind {
        switch self {
        case .text: return .text
        case .image: return .image
        case .video: return .video
        case .file: return .file
        }
    }
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
    let contentType: EnvelopePayloadKind
    let createdAt: Date
}

/// The result of a backfill sync.
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
