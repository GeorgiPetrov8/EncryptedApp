import Foundation
import CryptoKit

/// Long-term identity key material: an X25519 agreement key and an Ed25519
/// signing key (CryptoKit has no single type that does both).
struct IdentityKeyPair {
    let agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    let signingPrivateKey: Curve25519.Signing.PrivateKey

    var agreementPublicKey: Curve25519.KeyAgreement.PublicKey { agreementPrivateKey.publicKey }
    var signingPublicKey: Curve25519.Signing.PublicKey { signingPrivateKey.publicKey }

    static func generate() -> IdentityKeyPair {
        IdentityKeyPair(
            agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey(),
            signingPrivateKey: Curve25519.Signing.PrivateKey()
        )
    }

    func rawRepresentation() -> Data {
        agreementPrivateKey.rawRepresentation + signingPrivateKey.rawRepresentation
    }

    static func from(rawRepresentation data: Data) throws -> IdentityKeyPair {
        guard data.count == 64 else { throw CryptoError.invalidKeyData }
        let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data.prefix(32))
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: data.suffix(32))
        return IdentityKeyPair(agreementPrivateKey: agreement, signingPrivateKey: signing)
    }
}

/// Medium-term key, rotated periodically, signed by the identity key.
struct SignedPreKey {
    let id: UInt32
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let signature: Data
    let createdAt: Date

    var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }

    static let rotationInterval: TimeInterval = 30 * 24 * 60 * 60
    static let gracePeriod: TimeInterval = 7 * 24 * 60 * 60

    var age: TimeInterval { Date().timeIntervalSince(createdAt) }
    var needsRotation: Bool { age >= Self.rotationInterval }

    /// The bytes that get signed (S8): `"SHC-spk-v1" || publicKey`.
    static func signedMessage(for publicKey: Data) -> Data {
        ProtocolV2.signedPreKeyContext + publicKey
    }

    static func generate(id: UInt32, signedBy identity: IdentityKeyPair, createdAt: Date = Date()) throws -> SignedPreKey {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let signature = try identity.signingPrivateKey.signature(for: signedMessage(for: priv.publicKey.rawRepresentation))
        return SignedPreKey(id: id, privateKey: priv, signature: signature, createdAt: createdAt)
    }

    /// v2 signature, or (while allowed) the legacy signature over the bare key.
    static func isValidSignature(
        _ signature: Data,
        for publicKey: Data,
        signedBy signingKey: Curve25519.Signing.PublicKey,
        allowLegacy: Bool
    ) -> Bool {
        if signingKey.isValidSignature(signature, for: signedMessage(for: publicKey)) { return true }
        return allowLegacy && signingKey.isValidSignature(signature, for: publicKey)
    }

    /// True if this key was signed the old way and should be replaced now.
    func hasLegacySignature(identity: IdentityKeyPair) -> Bool {
        !identity.signingPublicKey.isValidSignature(signature, for: Self.signedMessage(for: publicKey.rawRepresentation))
    }
}

/// One-time prekeys; consumed after a single use by the responder.
struct OneTimePreKey {
    let id: UInt32
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }

    static func generateBatch(count: Int, startingId: UInt32 = 0) -> [OneTimePreKey] {
        (0..<count).map {
            OneTimePreKey(id: startingId + UInt32($0), privateKey: Curve25519.KeyAgreement.PrivateKey())
        }
    }
}

enum CryptoError: LocalizedError, Equatable {
    case invalidKeyData
    case invalidSignature
    case sessionNotReady
    case awaitingFirstMessage
    case tooManySkippedMessages
    case sealFailed
    case unknownPreKeyId
    case noOneTimePreKeysAvailable
    case noActiveAccount
    case identityAlreadyExists
    /// NEW: the message was made with a different protocol version than this
    /// conversation's session (one phone not updated, or a downgrade attempt).
    case protocolMismatch

    var errorDescription: String? {
        switch self {
        case .invalidKeyData: return "The key material is malformed."
        case .invalidSignature: return "The contact's prekey signature didn't verify."
        case .sessionNotReady: return "This conversation's encryption state is unusable. Start a new conversation with this contact."
        case .awaitingFirstMessage: return "Waiting for your contact's first message — the secure channel isn't established in both directions yet."
        case .tooManySkippedMessages: return "Too many messages are missing from this conversation to catch up safely."
        case .sealFailed: return "Encryption failed."
        case .unknownPreKeyId: return "The sender used a prekey this device no longer has. Ask them to start a new conversation."
        case .noOneTimePreKeysAvailable: return "No one-time prekeys are available."
        case .noActiveAccount: return "No account is currently active on this device."
        case .identityAlreadyExists: return "Key material already exists for this account."
        case .protocolMismatch: return "This message was sent by a different version of SecureHyperChat. Both of you need to update the app."
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .awaitingFirstMessage, .tooManySkippedMessages:
            return true
        case .invalidKeyData, .invalidSignature, .sessionNotReady, .sealFailed, .unknownPreKeyId,
             .noOneTimePreKeysAvailable, .noActiveAccount, .identityAlreadyExists, .protocolMismatch:
            return false
        }
    }
}
