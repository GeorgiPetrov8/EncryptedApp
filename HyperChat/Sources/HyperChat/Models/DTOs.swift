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

/// What the server hands out when a peer wants to start a session with a
/// user. All fields are public keys / signatures — nothing here lets the
/// server decrypt anything (zero-knowledge principle from the spec).
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

/// The non-destructive directory lookup (Bug #11's fix) — never consumes a
/// one-time prekey, unlike `PreKeyBundle`.
struct DirectoryEntry: Codable, Equatable {
    let userId: String
    let username: String
    let identityAgreementKey: Data
    let identitySigningKey: Data
}

// MARK: - X3DH handshake payload

/// Sent alongside the very first message in a new conversation so the
/// responder can derive the same shared secret the initiator did.
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
/// FIX (shared notepad): deliberately a **separate type** from
/// `MessageContentType`, not an added case on it.
///
/// `MessageContentType` is also the type of `Message.contentType` — a
/// column on rows that get rendered as chat bubbles, previewed in the
/// conversation list, etc. A notepad sync operation never becomes a
/// `Message` row at all (see `MessagingService.handleIncoming`'s early
/// return for `.notePad`), so adding it to `MessageContentType` would mean
/// every exhaustive `switch` over that type — the bubble icon, the preview
/// text, media-detection helpers — gains a case that can never actually
/// occur for a persisted message, purely defensive dead code with no way
/// for the compiler to confirm it's really unreachable.
///
/// Keeping them separate makes the impossible state unrepresentable
/// instead of merely unreached: `asMessageContentType` below is the only
/// bridge between the two, and it's `nil` for exactly the one case
/// (`.notePad`) that should never reach message-row construction.
/// Extends the envelope payload kinds with the control messages this pack adds.
///
/// Replaces the `EnvelopePayloadKind` from the notepad pack. Same design
/// reasoning: these are *not* cases on `MessageContentType`, because none of
/// them ever becomes a chat bubble, and adding them there would force every
/// exhaustive switch over message content to handle states that cannot occur
/// for a persisted message.
enum EnvelopePayloadKind: String, Codable, Equatable {
    case text
    case image
    case video
    case file
    /// A `NotePadOperation`.
    case notePad
    /// FIX (feature #3): a `ReceiptPayload` — delivered/read acknowledgement.
    case receipt
    /// FIX (feature #4): a `ProfilePayload` — display name and avatar.
    case profile
    /// FIX (feature #6): an `InvitePayload` — contact request or its answer.
    case invite

    var asMessageContentType: MessageContentType? {
        switch self {
        case .text: return .text
        case .image: return .image
        case .video: return .video
        case .file: return .file
        case .notePad, .receipt, .profile, .invite: return nil
        }
    }

    /// Control payloads are merged into local state and never rendered in the
    /// timeline. Grouping the test here keeps `handleIncoming` from growing a
    /// long `if kind == .a || kind == .b ||` chain that someone forgets to
    /// extend when a new kind is added.
    var isControlMessage: Bool {
        asMessageContentType == nil
    }
}

extension MessageContentType {
    /// The inverse of `EnvelopePayloadKind.asMessageContentType`. Total —
    /// every `MessageContentType` has a corresponding wire representation —
    /// because only `.notePad` is one-directional, and that direction never
    /// starts from a `MessageContentType` in the first place (nothing
    /// constructs a `Message` to *become* a notepad sync; it's the other
    /// way around, see `MessagingService.sendNotePadOperation`).
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
    /// FIX (shared notepad): was `MessageContentType`, now
    /// `EnvelopePayloadKind` — see that type's doc comment for why.
    /// Wire-compatible: both encode to the same four lowercase strings for
    /// every case they share, and the server's `validate.js` allow-list
    /// checks the raw string regardless of which Swift enum backs it.
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
