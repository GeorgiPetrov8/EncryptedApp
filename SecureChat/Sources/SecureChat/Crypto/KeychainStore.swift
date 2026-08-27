import Foundation
import CryptoKit
import Security

/// Minimal wrapper around the Keychain Services API. Everything stored here
/// uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never synced to
/// iCloud Keychain, never accessible before first unlock.
///
/// Note on Secure Enclave: the Secure Enclave only supports P-256 key
/// agreement/signing, not Curve25519 (X25519/Ed25519) used by X3DH/Double
/// Ratchet here. So identity keys below are software keys protected by the
/// Keychain's own encryption, not SE-backed. If you need SE-backed keys,
/// you'd need to move the protocol to P-256, which is a bigger change.
///
/// FIX (Bug #10): every account's key material now lives under a per-user
/// namespace. Previously all accounts shared one flat set of accounts within
/// service `com.securechat.keys`, so registering a second account silently
/// overwrote the first account's `localStorageKey` and identity — destroying
/// the first account's history and, worse, letting a login as user B load
/// user A's identity keys.
final class KeychainStore {
    enum KeychainError: Error { case unhandled(OSStatus), notFound, accessControlFailed }

    private let service: String

    init(service: String = "com.securechat.keys") {
        self.service = service
    }

    /// Namespaces a logical key name to a specific account.
    /// Kept as a single function so the format can never drift between
    /// save/load/delete paths.
    static func namespaced(_ key: String, userId: String) -> String {
        "\(userId)::\(key)"
    }

    // MARK: Save / load / delete

    /// - Parameter requireUserPresence: when true, the item is protected by a
    ///   `SecAccessControl` with `.userPresence`, so reading it prompts for Face ID /
    ///   Touch ID / passcode. FIX (Bug #6): this is the real local-secret protection,
    ///   replacing the password that never actually guarded anything.
    func save(key: String, data: Data, requireUserPresence: Bool = false) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary) // overwrite semantics

        var attributes = query
        attributes[kSecValueData as String] = data

        if requireUserPresence {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &error
            ) else {
                throw KeychainError.accessControlFailed
            }
            attributes[kSecAttrAccessControl as String] = access
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    func load(key: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { throw KeychainError.notFound }
            throw KeychainError.unhandled(status)
        }
        return data
    }

    func loadIfPresent(key: String) -> Data? {
        try? load(key: key)
    }

    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Enumeration (Bug #10 — needed for deleteAccount)

    /// All account names stored under this service.
    ///
    /// Without this there is no way to delete an account completely: the one-time
    /// prekey entries (`otk_<id>`) and rotated signed prekeys (`signedPreKey_<id>`)
    /// are dynamically named, so a fixed list of key constants can never cover them.
    func allAccountNames() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Deletes every item belonging to one account namespace.
    func deleteAll(forUserId userId: String) {
        let prefix = Self.namespaced("", userId: userId)
        for account in allAccountNames() where account.hasPrefix(prefix) {
            delete(key: account)
        }
    }
}

// NOTE (Bug #6): `PBKDF2` has been removed.
//
// It existed solely to derive a key from the user's password in
// `AuthService.register`, where the result was immediately discarded with `_ =`.
// The password guarded nothing: `login` never used it, and `MockBackendStore.login`
// resolved an account by username alone.
//
// Rather than build a real passphrase-gated unlock on top of a hand-rolled,
// main-thread-blocking KDF, SecureChat now relies on the platform: the local storage
// key is stored with `.userPresence` access control (see `CryptoService`), so reading
// it requires Face ID / Touch ID / device passcode. That is stronger than a
// user-chosen password, cannot be forgotten, and involves no custom crypto.
//
// If you later need cross-device key escrow (where a password genuinely is the only
// option because the Secure Enclave can't travel), reintroduce a KDF — but use
// `CCKeyDerivationPBKDF` from CommonCrypto, off the main actor, and derive from a
// per-account salt.
