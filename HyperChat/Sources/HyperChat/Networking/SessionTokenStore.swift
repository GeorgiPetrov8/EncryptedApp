import Foundation

/// Holds the server-issued bearer token, independent of `AuthService`.
///
/// This exists purely to break a dependency cycle. `AuthService`'s
/// initializer already takes an `apiClient: APIClientProtocol` (it calls
/// `register`/`login` on it) — so `apiClient` has to exist *before*
/// `AuthService` does. But `RealAPIClient` needs the current session token
/// on every *other* call, and the natural place to keep "the current
/// session token" would be `AuthService` itself, which doesn't exist yet at
/// that point.
///
/// `SessionTokenStore` is the shared, dependency-free thing both sides can
/// hold: `AppContainer` constructs it first, hands it to `RealAPIClient`
/// (which only reads from it) and to `AuthService` (which writes to it on
/// register/login/logout). Neither of those two ever needs a reference to
/// the other.
final class SessionTokenStore {
    private let keychain: KeychainStore
    private enum Keys {
        static let token = "sessionToken"
    }

    init(keychain: KeychainStore = KeychainStore(service: "com.HyperChat.session")) {
        self.keychain = keychain
    }

    var currentToken: String? {
        keychain.loadIfPresent(key: Keys.token).flatMap { String(data: $0, encoding: .utf8) }
    }

    func save(_ token: String) throws {
        try keychain.save(key: Keys.token, data: Data(token.utf8))
    }

    func clear() {
        keychain.delete(key: Keys.token)
    }
}
