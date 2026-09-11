import Foundation
import CryptoKit

/// FIX (Bug #2): human-comparable representation of two identities.
///
/// The app previously had no way to tell the user *who* they were actually talking
/// to. `X3DH.initiate` verifies the signature over the signed prekey — but with the
/// signing key from the same bundle, so a malicious server that swaps the whole
/// bundle passes that check trivially and reads the entire conversation.
///
/// A safety number is derived from both parties' long-term identity keys. If the two
/// users compare it out of band (in person, over a phone call) and it matches, no
/// machine-in-the-middle is present. Order-independent by construction, so both sides
/// display the same string.
enum SafetyNumber {

    /// Number of 5-digit groups shown to the user.
    static let groupCount = 12
    private static let digitsPerGroup = 5
    private static let bytesPerGroup = 5

    /// Stable per-identity blob: agreement key followed by signing key.
    static func identityBlob(agreementKey: Data, signingKey: Data) -> Data {
        agreementKey + signingKey
    }

    /// Formatted safety number, e.g. "12345 67890 …" (12 groups of 5 digits).
    ///
    /// Both identity blobs are sorted lexicographically before hashing, which is what
    /// makes the result identical regardless of which side computes it.
    static func format(
        myAgreementKey: Data,
        mySigningKey: Data,
        peerAgreementKey: Data,
        peerSigningKey: Data
    ) -> String {
        let mine = identityBlob(agreementKey: myAgreementKey, signingKey: mySigningKey)
        let theirs = identityBlob(agreementKey: peerAgreementKey, signingKey: peerSigningKey)

        let ordered = [mine, theirs].sorted { lhs, rhs in
            lhs.lexicographicallyPrecedes(rhs)
        }

        var input = Data("SecureChat SafetyNumber v1".utf8)
        ordered.forEach { input.append($0) }

        // SHA-512 gives 64 bytes; we need groupCount × bytesPerGroup = 60.
        let digest = Data(SHA512.hash(data: input))

        var groups: [String] = []
        groups.reserveCapacity(groupCount)

        for groupIndex in 0..<groupCount {
            let start = groupIndex * bytesPerGroup
            let chunk = digest[digest.startIndex.advanced(by: start)..<digest.startIndex.advanced(by: start + bytesPerGroup)]

            // 5 bytes → up to 2^40, reduced into a 5-digit decimal group.
            var value: UInt64 = 0
            for byte in chunk {
                value = (value << 8) | UInt64(byte)
            }
            let group = value % 100_000
            groups.append(String(format: "%0\(digitsPerGroup)d", group))
        }

        return groups.joined(separator: " ")
    }

    /// Short hex fingerprint, useful for logs and debugging. Never shown as the
    /// primary verification affordance — the digit groups are far easier to read aloud.
    static func shortFingerprint(agreementKey: Data, signingKey: Data) -> String {
        let digest = Data(SHA256.hash(data: identityBlob(agreementKey: agreementKey, signingKey: signingKey)))
        return digest.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
