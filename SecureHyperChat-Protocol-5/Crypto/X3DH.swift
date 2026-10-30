import Foundation
import CryptoKit

/// Extended Triple Diffie-Hellman: the initial shared secret, from published
/// prekeys. Educational implementation of the shape of Signal's X3DH; not
/// independently audited.
enum X3DH {
    struct InitiatorResult {
        let rootKey: SymmetricKey
        let usedOneTimePreKeyId: UInt32?
        let ephemeralPublicKey: Curve25519.KeyAgreement.PublicKey
        /// NEW (S7): both identities, to bind into the session.
        let associatedData: Data
    }

    /// Alice's side: she has fetched Bob's bundle from the server.
    ///
    /// FIX (S8): the signed prekey must carry a signature over
    /// `"SHC-spk-v1" || key`. A signature over the bare key is accepted only
    /// while `ProtocolV2.acceptLegacy` is true (phones not yet updated).
    static func initiate(myIdentity: IdentityKeyPair, bundle: PreKeyBundle) throws -> InitiatorResult {
        let bobSigningKey = try Curve25519.Signing.PublicKey(rawRepresentation: bundle.identitySigningKey)
        guard SignedPreKey.isValidSignature(
            bundle.signedPreKeySignature,
            for: bundle.signedPreKey,
            signedBy: bobSigningKey,
            allowLegacy: ProtocolV2.acceptLegacy
        ) else {
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

        return InitiatorResult(
            rootKey: deriveRootKey(dh1: dh1, dh2: dh2, dh3: dh3, dh4: dh4),
            usedOneTimePreKeyId: bundle.oneTimePreKeyId,
            ephemeralPublicKey: ephemeral.publicKey,
            associatedData: ProtocolV2.sessionAssociatedData(
                initiatorAgreementKey: myIdentity.agreementPublicKey.rawRepresentation,
                initiatorSigningKey: myIdentity.signingPublicKey.rawRepresentation,
                responderAgreementKey: bundle.identityAgreementKey,
                responderSigningKey: bundle.identitySigningKey
            )
        )
    }

    /// Bob's side.
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

    /// HKDF info unchanged on purpose (D10).
    private static func deriveRootKey(dh1: SharedSecret, dh2: SharedSecret, dh3: SharedSecret, dh4: SharedSecret?) -> SymmetricKey {
        var combined = Data(repeating: 0xFF, count: 32)
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
