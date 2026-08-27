import Foundation
import CryptoKit

/// Tiny convenience so call sites don't need to spell out
/// `Curve25519.KeyAgreement.PublicKey(rawRepresentation:)` everywhere.
enum CurveKeyHelper {
    typealias PrivateAgreementKey = Curve25519.KeyAgreement.PrivateKey
    typealias PublicAgreementKey = Curve25519.KeyAgreement.PublicKey

    static func publicKey(from raw: Data) throws -> PublicAgreementKey {
        try PublicAgreementKey(rawRepresentation: raw)
    }
}
