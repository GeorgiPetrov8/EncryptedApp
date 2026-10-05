import Foundation
import CryptoKit

extension CryptoService {
    /// Signs `message` with the active account's Ed25519 identity key.
    ///
    /// Used for the server's login and account-deletion challenges. The
    /// signing key is taken from the stored identity and checked against the
    /// public signing key, so a wrong half can never be used by mistake.
    func signWithIdentity(_ message: Data) throws -> Data {
        guard let identity else { throw CryptoError.noActiveAccount }
        let raw = try identity.rawRepresentation()
        let expected = identity.signingPublicKey.rawRepresentation

        guard raw.count >= 64 else { throw CryptoError.invalidKeyData }
        let candidates = [(raw.count - 32)..<raw.count, 0..<32]
        for range in candidates {
            if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw.subdata(in: range)),
               key.publicKey.rawRepresentation == expected {
                return try key.signature(for: message)
            }
        }
        throw CryptoError.invalidKeyData
    }

    /// Signs a server challenge after checking it's for `userId`.
    func signChallenge(_ challenge: LoginChallenge, expectedUserId: String? = nil) throws -> Data {
        if let expectedUserId, challenge.userId != expectedUserId {
            throw AuthError.userIdMismatch
        }
        guard let nonce = Data(base64Encoded: challenge.nonce) else { throw CryptoError.invalidKeyData }
        return try signWithIdentity(nonce)
    }
}
