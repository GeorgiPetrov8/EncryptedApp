import Foundation
import CryptoKit
import Security

/// Minimal wrapper around the Keychain Services API. Everything stored here
/// uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never synced to
/// iCloud Keychain, never accessible before first unlock.
///
/// Note on Secure Enclave: the Secure Enclave only supports P-256, not the
/// Curve25519 keys X3DH/Double Ratchet use here, so identity keys are software
/// keys protected by the Keychain's own encryption.
///
/// Every account's key material lives under a per-user namespace (Bug #10).
final class KeychainStore {
    enum KeychainError: Error { case unhandled(OSStatus), notFound, accessControlFailed }

    private let service: String

    /// The service name is unchanged on purpose: renaming it would orphan every
    /// key already stored on users' phones.
    init(service: String = "com.HyperChat.keys") {
        self.service = service
    }

    static func namespaced(_ key: String, userId: String) -> String {
        "\(userId)::\(key)"
    }

    // MARK: Save / load / delete

    /// FIX (R3): update in place, add only if missing.
    ///
    /// The old version deleted the item first and then added the new one. If the
    /// add failed — device locked, Keychain busy, access-control error — the old
    /// value was already gone. For the identity key that meant the account was
    /// lost for good. Now the old value is only replaced once the new one has been
    /// written successfully.
    ///
    /// Items protected with `.userPresence` can't be updated without prompting, and
    /// their access control can't be changed by an update, so those still use
    /// delete-then-add — but only after the new item has been staged under a
    /// temporary name, so a failure leaves the original in place.
    func save(key: String, data: Data, requireUserPresence: Bool = false) throws {
        if requireUserPresence {
            try saveWithUserPresence(key: key, data: data)
            return
        }

        let query = baseQuery(key)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        default:
            throw KeychainError.unhandled(status)
        }
    }

    private func saveWithUserPresence(key: String, data: Data) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error
        ) else { throw KeychainError.accessControlFailed }

        // 1. Stage the new value under a temporary name.
        let stagingKey = key + ".staging"
        SecItemDelete(baseQuery(stagingKey) as CFDictionary)
        var staged = baseQuery(stagingKey)
        staged[kSecValueData as String] = data
        staged[kSecAttrAccessControl as String] = access
        let stageStatus = SecItemAdd(staged as CFDictionary, nil)
        guard stageStatus == errSecSuccess else { throw KeychainError.unhandled(stageStatus) }

        // 2. Replace the real item. If adding fails, the staged copy survives and
        //    the original was only removed in the same step.
        SecItemDelete(baseQuery(key) as CFDictionary)
        var attributes = baseQuery(key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessControl as String] = access
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }

        // 3. Drop the staging copy.
        SecItemDelete(baseQuery(stagingKey) as CFDictionary)
    }

    func load(key: String) throws -> Data {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                // A user-presence save interrupted between steps 2 and 3 left the
                // new value only under the staging name.
                if !key.hasSuffix(".staging"), let staged = try? load(key: key + ".staging") {
                    return staged
                }
                throw KeychainError.notFound
            }
            throw KeychainError.unhandled(status)
        }
        return data
    }

    func loadIfPresent(key: String) -> Data? {
        try? load(key: key)
    }

    func delete(key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    // MARK: Enumeration (Bug #10 — needed for deleteAccount)

    func allAccountNames() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func deleteAll(forUserId userId: String) {
        let prefix = Self.namespaced("", userId: userId)
        for account in allAccountNames() where account.hasPrefix(prefix) {
            delete(key: account)
        }
    }
}
