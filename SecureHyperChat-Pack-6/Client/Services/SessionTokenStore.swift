import Foundation

/// Holds the server-issued bearer tokens — **one per account** (R8).
///
/// Before, there was a single token for the whole phone, so signing in to a
/// second account overwrote the first one's session, and switching back meant
/// signing in again. Now each account keeps its own token in the Keychain
/// (namespaced by user id) and one of them is "active": the token
/// `RealAPIClient` and the WebSocket use.
///
/// A token saved by an older version (single, un-namespaced) is moved to the
/// first account that becomes active.
final class SessionTokenStore {
    private let keychain: KeychainStore

    private enum Keys {
        static let legacyToken = "sessionToken"
        static let activeUser = "activeTokenUser"
        static let token = "sessionToken"
    }

    init(keychain: KeychainStore = KeychainStore(service: "com.HyperChat.session")) {
        self.keychain = keychain
    }

    // MARK: Active account

    var activeUserId: String? {
        keychain.loadIfPresent(key: Keys.activeUser).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Makes `userId`'s token the one used for requests.
    func activate(userId: String) {
        try? keychain.save(key: Keys.activeUser, data: Data(userId.utf8))
        if token(for: userId) == nil, let legacy = keychain.loadIfPresent(key: Keys.legacyToken) {
            try? keychain.save(key: key(for: userId), data: legacy)
        }
        keychain.delete(key: Keys.legacyToken)
    }

    /// No account active (e.g. "Add account"); every token is kept.
    func deactivate() {
        keychain.delete(key: Keys.activeUser)
    }

    // MARK: Tokens

    private func key(for userId: String) -> String {
        KeychainStore.namespaced(Keys.token, userId: userId)
    }

    func token(for userId: String) -> String? {
        keychain.loadIfPresent(key: key(for: userId)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The active account's token.
    var currentToken: String? {
        activeUserId.flatMap { token(for: $0) }
    }

    /// Saves for the active account.
    func save(_ token: String) throws {
        guard let userId = activeUserId else { throw APIError.notAuthenticated }
        try save(token, for: userId)
    }

    func save(_ token: String, for userId: String) throws {
        try keychain.save(key: key(for: userId), data: Data(token.utf8))
    }

    /// Logout of the active account: its token is removed, others stay.
    func clear() {
        if let userId = activeUserId {
            keychain.delete(key: key(for: userId))
        }
        keychain.delete(key: Keys.activeUser)
        keychain.delete(key: Keys.legacyToken)
    }

    /// Account deletion.
    func removeAll(userId: String) {
        keychain.delete(key: key(for: userId))
        if activeUserId == userId { keychain.delete(key: Keys.activeUser) }
    }
}
