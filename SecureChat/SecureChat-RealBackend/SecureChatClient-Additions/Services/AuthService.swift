import Foundation
import Combine
import os

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var currentUserId: String?
    @Published private(set) var currentUsername: String?
    @Published private(set) var isStorageUnlocked = false

    private let cryptoService: CryptoService
    private let apiClient: APIClientProtocol
    private let userRepository: UserRepository
    private let keychain = KeychainStore(service: "com.securechat.session")
    private let logger = Logger(subsystem: "com.securechat", category: "auth")

    /// FIX (real backend): the server-issued bearer token this account
    /// authenticates with on every request after register/login.
    ///
    /// Every prior version of this file only ever used `token.userId` from
    /// `AuthToken` and silently discarded `token.token` — harmless against
    /// `MockBackendStore`, which never checked it, but a real server rejects
    /// every request without a valid `Authorization: Bearer` header. Writes
    /// go through `SessionTokenStore` rather than this file's own Keychain
    /// instance so `RealAPIClient`/`RealWebSocketService` can read the
    /// current token without depending on `AuthService` — see
    /// `SessionTokenStore`'s own documentation for why that avoids a
    /// construction-order dependency cycle in `AppContainer`.
    private let tokenStore: SessionTokenStore

    private var onLogout: ((String) -> Void)?

    private enum Keys {
        static let userId = "sessionUserId"
        static let username = "sessionUsername"
    }

    var isAuthenticated: Bool { currentUserId != nil }

    init(
        cryptoService: CryptoService,
        apiClient: APIClientProtocol,
        userRepository: UserRepository,
        tokenStore: SessionTokenStore
    ) {
        self.cryptoService = cryptoService
        self.apiClient = apiClient
        self.userRepository = userRepository
        self.tokenStore = tokenStore
        restoreSessionIfPossible()
    }

    func setLogoutHandler(_ handler: @escaping (String) -> Void) {
        onLogout = handler
    }

    private func restoreSessionIfPossible() {
        guard
            let userIdData = keychain.loadIfPresent(key: Keys.userId),
            let usernameData = keychain.loadIfPresent(key: Keys.username),
            let userId = String(data: userIdData, encoding: .utf8),
            let username = String(data: usernameData, encoding: .utf8),
            cryptoService.hasIdentity(forUserId: userId)
        else { return }

        // FIX (real backend): a restored session with no stored bearer token
        // can't make authenticated requests at all — this happens if the app
        // was reinstalled (Keychain items can survive that on some
        // configurations) or if a mock-backend build's session is restored
        // against a real-backend build. Treat it as "not actually signed in"
        // rather than presenting a UI that will fail on the first request.
        guard tokenStore.currentToken != nil else {
            logger.error("Session restore found identity but no session token; requiring re-login")
            return
        }

        do {
            try cryptoService.loadIdentityFromKeychain(userId: userId)
            currentUserId = userId
            currentUsername = username
            isStorageUnlocked = false
        } catch {
            logger.error("Session restore failed; keeping the user signed out")
        }
    }

    @discardableResult
    func unlockStorage() async -> Bool {
        guard isAuthenticated, !isStorageUnlocked else { return isStorageUnlocked }
        do {
            try cryptoService.unlockStorageKey()
            isStorageUnlocked = true
            return true
        } catch {
            logger.error("Storage key unlock failed")
            return false
        }
    }

    /// Registers a brand-new account (Bug #6: no password).
    func register(username: String) async throws {
        let userId = UUID().uuidString

        let bundle = try cryptoService.generateIdentityAndBundle(userId: userId, username: username)

        let token: AuthToken
        do {
            token = try await apiClient.register(username: username, bundle: bundle)
        } catch {
            cryptoService.deleteAccount(userId: userId)
            throw error
        }

        guard token.userId == userId else {
            logger.error("Server returned a different user id than requested")
            cryptoService.deleteAccount(userId: userId)
            throw AuthError.userIdMismatch
        }

        try userRepository.upsert(User(
            ownerUserId: token.userId,
            id: token.userId,
            username: username,
            publicKey: bundle.identityAgreementKey,
            createdAt: Date(),
            identitySigningKey: bundle.identitySigningKey,
            isVerified: true
        ))

        try keychain.save(key: Keys.userId, data: Data(token.userId.utf8))
        try keychain.save(key: Keys.username, data: Data(username.utf8))
        // FIX (real backend): persist the bearer token alongside the
        // session pointer. Without this line the account could register
        // successfully and then fail the very next network call.
        try tokenStore.save(token.token)

        currentUserId = token.userId
        currentUsername = username
        isStorageUnlocked = true
    }

    /// Loads the identity belonging to the account being signed into (Bug #10).
    func login(username: String) async throws {
        let token = try await apiClient.login(username: username)

        guard cryptoService.hasIdentity(forUserId: token.userId) else {
            throw AuthError.noLocalIdentityForAccount
        }

        try cryptoService.loadIdentityFromKeychain(userId: token.userId)
        try cryptoService.unlockStorageKey()

        try keychain.save(key: Keys.userId, data: Data(token.userId.utf8))
        try keychain.save(key: Keys.username, data: Data(username.utf8))
        // FIX (real backend): a fresh login issues a fresh server-side
        // session (see `auth.js`'s `issueToken` — the old one, if any, is
        // simply superseded rather than explicitly revoked).
        try tokenStore.save(token.token)

        currentUserId = token.userId
        currentUsername = username
        isStorageUnlocked = true
    }

    /// Clears in-memory secrets, the session pointer, and the bearer token —
    /// but never deletes key material (Bug #10: logout must not destroy history).
    func logout() {
        let departingUserId = currentUserId

        cryptoService.deactivate()
        if let departingUserId {
            onLogout?(departingUserId)
        }
        currentUserId = nil
        currentUsername = nil
        isStorageUnlocked = false
        keychain.delete(key: Keys.userId)
        keychain.delete(key: Keys.username)
        // FIX (real backend): without this, the token for the account that
        // just logged out remains in the Keychain and — because
        // `SessionTokenStore` is keyed by Keychain service, not by user —
        // would be picked up and sent as the *next* signed-in account's
        // bearer token. The server would (correctly) reject it as belonging
        // to someone else's session, surfacing as a confusing 401/403 on
        // the very first request after switching accounts on one device.
        tokenStore.clear()
    }
}

enum AuthError: LocalizedError {
    case noLocalIdentityForAccount
    case userIdMismatch

    var errorDescription: String? {
        switch self {
        case .noLocalIdentityForAccount:
            return "This device has no keys for that account. Keys never leave the device that created them."
        case .userIdMismatch:
            return "The server returned an unexpected account id."
        }
    }
}
