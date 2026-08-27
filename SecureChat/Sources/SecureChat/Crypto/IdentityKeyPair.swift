import Foundation
import CryptoKit

/// Long-term identity key material for a user.
///
/// We keep two separate CryptoKit key types because X25519 (key agreement)
/// and Ed25519 (signing) are different curves in CryptoKit — there is no
/// single "identity key" type that does both, so, like Signal's protocol,
/// we carry an agreement key (for DH) and a signing key (to sign the
/// Signed PreKey so peers can verify it hasn't been tampered with).
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

    /// Serialized as two raw 32-byte keys concatenated, for Keychain storage.
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

/// Medium-term key, rotated periodically, signed by the identity key so a
/// peer can trust it came from that identity.
///
/// FIX (Bug #7): now carries `createdAt`. Rotation needs to know a key's age, and
/// the responder needs to keep superseded keys around for a grace period so that
/// handshakes already in flight against the previous prekey still succeed.
struct SignedPreKey {
    let id: UInt32
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let signature: Data
    let createdAt: Date

    var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }

    /// How long before a signed prekey is replaced.
    static let rotationInterval: TimeInterval = 30 * 24 * 60 * 60 // 30 days

    /// How long a superseded signed prekey is retained after rotation, to cover
    /// handshakes started against it before the peer saw the new bundle.
    static let gracePeriod: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    var age: TimeInterval { Date().timeIntervalSince(createdAt) }
    var needsRotation: Bool { age >= Self.rotationInterval }

    static func generate(id: UInt32, signedBy identity: IdentityKeyPair, createdAt: Date = Date()) throws -> SignedPreKey {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let signature = try identity.signingPrivateKey.signature(for: priv.publicKey.rawRepresentation)
        return SignedPreKey(id: id, privateKey: priv, signature: signature, createdAt: createdAt)
    }
}

/// One-time prekeys give the very first message extra forward secrecy.
/// Each is consumed (deleted) after a single use by the responder.
///
/// NOTE (Bug #1): `CryptoService.generateOneTimePreKeys` is now the only producer,
/// because it also owns the monotonic id allocator and the Keychain persistence.
/// `generateBatch` below is unused and kept only to avoid breaking any external
/// reference; prefer the service.
struct OneTimePreKey {
    let id: UInt32
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }

    static func generateBatch(count: Int, startingId: UInt32 = 0) -> [OneTimePreKey] {
        (0..<count).map { OneTimePreKey(id: startingId + UInt32($0), privateKey: Curve25519.KeyAgreement.PrivateKey()) }
    }
}

enum CryptoError: LocalizedError {
    case invalidKeyData
    case invalidSignature
    case sessionNotReady
    case sealFailed
    case unknownPreKeyId
    case noOneTimePreKeysAvailable
    /// FIX (Bug #10): raised when `CryptoService` is used before an account is bound.
    case noActiveAccount
    /// FIX (Bug #10): raised instead of silently overwriting existing key material.
    case identityAlreadyExists

    /// FIX (Bug #9): crypto failures now reach the UI, so they need text a person
    /// can act on rather than "The operation couldn't be completed."
    var errorDescription: String? {
        switch self {
        case .invalidKeyData:
            return "The key material is malformed."
        case .invalidSignature:
            return "The contact's prekey signature didn't verify."
        case .sessionNotReady:
            return "This conversation isn't established yet — wait for the first message from your contact."
        case .sealFailed:
            return "Encryption failed."
        case .unknownPreKeyId:
            return "The sender used a prekey this device no longer has. Ask them to start a new conversation."
        case .noOneTimePreKeysAvailable:
            return "No one-time prekeys are available."
        case .noActiveAccount:
            return "No account is currently active on this device."
        case .identityAlreadyExists:
            return "Key material already exists for this account."
        }
    }
}
