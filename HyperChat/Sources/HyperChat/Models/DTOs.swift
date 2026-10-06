import Foundation

// MARK: - Public key material published to the server (X3DH)

struct OneTimePreKeyPublic: Codable, Equatable {
    let id: UInt32
    let publicKey: Data
}

struct SignedPreKeyUpload: Codable, Equatable {
    let userId: String
    let signedPreKeyId: UInt32
    let signedPreKey: Data
    let signedPreKeySignature: Data
}

struct PreKeyBundleUpload: Codable, Equatable {
    let userId: String
    let username: String
    let identityAgreementKey: Data
    let identitySigningKey: Data
    let signedPreKeyId: UInt32
    let signedPreKey: Data
    let signedPreKeySignature: Data
    let oneTimePreKeys: [OneTimePreKeyPublic]
}

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
enum EnvelopePayloadKind: String, Codable, Equatable {
    case text
    case image
    case video
    case file
    case notePad
    case receipt
    case profile
    case invite
    case call
    case edit
    /// NEW: a `ReactionPayload` — an emoji reaction to a message.
    case reaction

    var asMessageContentType: MessageContentType? {
        switch self {
        case .text: return .text
        case .image: return .image
        case .video: return .video
        case .file: return .file
        case .notePad, .receipt, .profile, .invite, .call, .edit, .reaction: return nil
        }
    }

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
