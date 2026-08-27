import Foundation
import CryptoKit

/// Extended Triple Diffie-Hellman: how two parties agree on an initial
/// shared secret before any messages have been exchanged, using only
/// public key material either has published (or, for the ephemeral key,
/// generates on the spot). This becomes the Double Ratchet's root key.
///
/// This is a from-scratch, educational implementation of the *shape* of
/// Signal's X3DH. It has not been independently audited. For a production
/// app, prefer a vetted implementation (e.g. libsignal) over hand-rolled
/// protocol code — the value of this scaffold is showing how the pieces
/// fit together, not replacing a reviewed crypto library.
enum X3DH {
    struct InitiatorResult {
        let rootKey: SymmetricKey
        let usedOneTimePreKeyId: UInt32?
        let ephemeralPublicKey: Curve25519.KeyAgreement.PublicKey
    }

    /// Alice's side: she has fetched Bob's `PreKeyBundle` from the server.
    static func initiate(myIdentity: IdentityKeyPair, bundle: PreKeyBundle) throws -> InitiatorResult {
        let bobSigningKey = try Curve25519.Signing.PublicKey(rawRepresentation: bundle.identitySigningKey)
        guard bobSigningKey.isValidSignature(bundle.signedPreKeySignature, for: bundle.signedPreKey) else {
            throw CryptoError.invalidSignature
        }

        let bobIdentityAgreement = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.identityAgreementKey)
        let bobSignedPreKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.signedPreKey)
        let bobOneTimePreKey = try bundle.oneTimePreKey.map {
            try Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0)
        }

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()

        let dh1 = try myIdentity.agreementPrivateKey.sharedSecretFromKeyAgreement(with: bobSignedPreKey)
        let dh2 = try ephemeral.sharedSecretFromKeyAgreement(with: bobIdentityAgreement)
        let dh3 = try ephemeral.sharedSecretFromKeyAgreement(with: bobSignedPreKey)
        let dh4 = try bobOneTimePreKey.map { try ephemeral.sharedSecretFromKeyAgreement(with: $0) }

        let rootKey = deriveRootKey(dh1: dh1, dh2: dh2, dh3: dh3, dh4: dh4)
        return InitiatorResult(
            rootKey: rootKey,
            usedOneTimePreKeyId: bundle.oneTimePreKeyId,
            ephemeralPublicKey: ephemeral.publicKey
        )
    }

    /// Bob's side: he receives Alice's identity key + ephemeral key (carried
    /// in the handshake payload of her first envelope) and reconstructs the
    /// same shared secret using the private halves of the prekeys she used.
    static func respond(
        myIdentity: IdentityKeyPair,
        mySignedPreKey: Curve25519.KeyAgreement.PrivateKey,
        myOneTimePreKey: Curve25519.KeyAgreement.PrivateKey?,
        aliceIdentityAgreementKey: Data,
        aliceEphemeralKey: Data
    ) throws -> SymmetricKey {
        let aliceIdentity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: aliceIdentityAgreementKey)
        let aliceEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: aliceEphemeralKey)

        let dh1 = try mySignedPreKey.sharedSecretFromKeyAgreement(with: aliceIdentity)
        let dh2 = try myIdentity.agreementPrivateKey.sharedSecretFromKeyAgreement(with: aliceEphemeral)
        let dh3 = try mySignedPreKey.sharedSecretFromKeyAgreement(with: aliceEphemeral)
        let dh4 = try myOneTimePreKey.map { try $0.sharedSecretFromKeyAgreement(with: aliceEphemeral) }

        return deriveRootKey(dh1: dh1, dh2: dh2, dh3: dh3, dh4: dh4)
    }

    private static func deriveRootKey(dh1: SharedSecret, dh2: SharedSecret, dh3: SharedSecret, dh4: SharedSecret?) -> SymmetricKey {
        var combined = Data(repeating: 0xFF, count: 32) // domain-separation prefix, per X3DH spec
        combined.append(dh1.withUnsafeBytes { Data($0) })
        combined.append(dh2.withUnsafeBytes { Data($0) })
        combined.append(dh3.withUnsafeBytes { Data($0) })
        if let dh4 { combined.append(dh4.withUnsafeBytes { Data($0) }) }

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: combined),
            salt: Data(repeating: 0x00, count: 32),
            info: Data("HyperChat X3DH v1".utf8),
            outputByteCount: 32
        )
    }
}
