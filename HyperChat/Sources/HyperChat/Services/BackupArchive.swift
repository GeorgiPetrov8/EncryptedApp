import Foundation
import CryptoKit
import CommonCrypto

/// Password-encrypted container for an account backup.
///
/// Layout:
///   "HCBK" | version (1 byte) | PBKDF2 rounds (UInt32 BE) | salt (16 bytes) | AES-GCM sealed box
///
/// The 25-byte header is authenticated as associated data, so nobody can lower
/// the round count (making the password cheaper to guess) without the file
/// failing to open. The payload is LZFSE-compressed before encryption.
///
/// The password never leaves the device and is not stored anywhere — if it's
/// forgotten, the backup cannot be opened by anyone, including us.
enum BackupArchive {
    static let magic = Data("HCBK".utf8)
    static let version: UInt8 = 1
    /// OWASP's 2023 recommendation for PBKDF2-HMAC-SHA256. Roughly half a
    /// second on a recent iPhone: noticeable once, expensive for a guesser.
    static let rounds: UInt32 = 600_000
    /// Refuses files that ask for absurd work (a crafted file could otherwise
    /// make the app hang trying to open it).
    private static let maxRounds: UInt32 = 10_000_000
    static let minimumPasswordLength = 10
    private static let headerLength = 4 + 1 + 4 + 16

    static func seal(_ plaintext: Data, password: String) async throws -> Data {
        try validate(password)
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BackupError.corrupted }

        var header = magic
        header.append(version)
        header.append(contentsOf: withUnsafeBytes(of: rounds.bigEndian) { Array($0) })
        header.append(salt)

        let compressed = try (plaintext as NSData).compressed(using: .lzfse) as Data
        let key = try await deriveKey(password: password, salt: salt, rounds: rounds)
        let sealed = try AES.GCM.seal(compressed, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw BackupError.corrupted }
        return header + combined
    }

    static func open(_ archive: Data, password: String) async throws -> Data {
        guard archive.count > headerLength + 28, archive.prefix(4) == magic else { throw BackupError.notABackup }
        let bytes = [UInt8](archive)
        guard bytes[4] == version else { throw BackupError.unsupportedVersion }

        let rounds = UInt32(bytes[5]) << 24 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 8 | UInt32(bytes[8])
        guard rounds >= 100_000, rounds <= maxRounds else { throw BackupError.corrupted }

        let header = archive.prefix(headerLength)
        let salt = archive.subdata(in: 9..<headerLength)
        let key = try await deriveKey(password: password, salt: salt, rounds: rounds)

        let compressed: Data
        do {
            let box = try AES.GCM.SealedBox(combined: archive.suffix(from: archive.startIndex + headerLength))
            compressed = try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            // AES-GCM can't tell a wrong password from a tampered file, and
            // shouldn't: either way the answer is "this password doesn't open it".
            throw BackupError.wrongPassword
        }
        do {
            return try (compressed as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw BackupError.corrupted
        }
    }

    static func validate(_ password: String) throws {
        guard password.count >= minimumPasswordLength else { throw BackupError.weakPassword }
    }

    /// PBKDF2-HMAC-SHA256 via CommonCrypto, off the main actor — at 600k rounds
    /// it would otherwise freeze the UI.
    private static func deriveKey(password: String, salt: Data, rounds: UInt32) async throws -> SymmetricKey {
        // Normalised so the same password typed on two keyboards derives the
        // same key (é as one code point vs e + combining accent).
        let normalized = password.precomposedStringWithCanonicalMapping
        return try await Task.detached(priority: .userInitiated) {
            let passwordBytes = Array(normalized.utf8)
            var derived = [UInt8](repeating: 0, count: 32)
            let status = salt.withUnsafeBytes { saltBuffer in
                passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                    passwordBuffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: passwordBytes.count) { passwordPointer in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            passwordPointer, passwordBytes.count,
                            saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                            rounds,
                            &derived, derived.count
                        )
                    }
                }
            }
            guard status == kCCSuccess else { throw BackupError.corrupted }
            return SymmetricKey(data: derived)
        }.value
    }
}

enum BackupError: LocalizedError {
    case notABackup
    case unsupportedVersion
    case wrongPassword
    case weakPassword
    case corrupted

    var errorDescription: String? {
        switch self {
        case .notABackup: return "This file isn't a HyperChat backup."
        case .unsupportedVersion: return "This backup was made by a newer version of HyperChat. Update the app first."
        case .wrongPassword: return "Wrong password, or the file is damaged."
        case .weakPassword: return "Use at least \(BackupArchive.minimumPasswordLength) characters."
        case .corrupted: return "The backup is damaged."
        }
    }
}
