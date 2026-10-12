import Foundation
import CryptoKit

/// Thin wrapper around CryptoKit's AES-256-GCM, used for both:
///  - Double Ratchet per-message encryption (transport)
///  - local-storage-at-rest encryption (see CryptoService)
///  - per-file media encryption (see MediaEncryptionService)
enum AESGCM {
    static func seal(plaintext: Data, key: SymmetricKey, associatedData: Data = Data()) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
        guard let combined = sealedBox.combined else { throw CryptoError.sealFailed }
        return combined // nonce || ciphertext || tag, as one blob
    }

    static func open(ciphertext: Data, key: SymmetricKey, associatedData: Data = Data()) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key, authenticating: associatedData)
    }

    static func randomKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }
}
