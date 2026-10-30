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
    private let keychain = KeychainStore(service: "com.HyperChat.session")
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "auth")
    private let tokenStore: SessionTokenStore

    private var onLogout: ((String) -> Void)?

    private enum Keys {
        static let userId = "sessionUserId"
        static let username = "sessionUsername"
        /// username (lowercased) → userId of accounts set up on this device (S9).
        static let knownAccounts = "knownAccounts"
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

    /// Called when the app locks: the storage key must be unlocked again with
    /// Face ID before messages are processed or shown.
    func lockStorage() {
        isStorageUnlocked = false
    }

    // MARK: Known accounts (S9)

    private func knownAccounts() -> [String: String] {
        guard let data = keychain.loadIfPresent(key: Keys.knownAccounts),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    private func remember(username: String, userId: String) {
        var map = knownAccounts()
        map[username.lowercased()] = userId
        if let data = try? JSONEncoder().encode(map) {
            try? keychain.save(key: Keys.knownAccounts, data: data)
        }
    }

    private func forget(userId: String) {
        var map = knownAccounts()
        map = map.filter { $0.value != userId }
        if let data = try? JSONEncoder().encode(map) {
            try? keychain.save(key: Keys.knownAccounts, data: data)
        }
    }

    // MARK: Register

    /// FIX (R7): if the server created the account but the response was lost
    /// (timeout, connection reset), the old code deleted the new keys — leaving a
    /// server account nobody could ever sign in to and a username taken forever.
    /// Now a failed registration first tries to sign in with the same keys; only
    /// if that also fails are they removed.
    func register(username: String) async throws {
        let userId = UUID().uuidString
        let bundle = try cryptoService.generateIdentityAndBundle(userId: userId, username: username)

        let token: AuthToken
        do {
            token = try await apiClient.register(username: username, bundle: bundle)
        } catch {
            if let recovered = try? await signIn(username: username, expectedUserId: userId) {
                remember(username: recovered.username, userId: userId)
                try establishSession(token: recovered.token, username: recovered.username, bundle: bundle)
                return
            }
            cryptoService.deleteAccount(userId: userId)
            throw error
        }

        guard token.userId == userId else {
            logger.error("Server returned a different user id than requested")
            cryptoService.deleteAccount(userId: userId)
            throw AuthError.userIdMismatch
        }

        remember(username: username, userId: userId)
        try establishSession(token: token, username: await canonicalUsername(userId: userId, fallback: username), bundle: bundle)
    }

    // MARK: Login

    /// Signs in to an account whose keys are on this device.
    ///
    /// FIX (S9): the challenge is only signed for the account this device expects
    /// for that username (when known). Before, the server could name any local
    /// account in the challenge and get this device to sign for it.
    /// FIX (R11): the stored username is the server's canonical spelling, not
    /// whatever case the user typed.
    func login(username: String) async throws {
        let expected = knownAccounts()[username.lowercased()]
        let result = try await signIn(username: username, expectedUserId: expected)

        try cryptoService.loadIdentityFromKeychain(userId: result.token.userId)
        try cryptoService.unlockStorageKey()

        remember(username: result.username, userId: result.token.userId)
        try keychain.save(key: Keys.userId, data: Data(result.token.userId.utf8))
        try keychain.save(key: Keys.username, data: Data(result.username.utf8))
        try tokenStore.save(result.token.token)

        currentUserId = result.token.userId
        currentUsername = result.username
        isStorageUnlocked = true
    }

    private func signIn(username: String, expectedUserId: String?) async throws -> (token: AuthToken, username: String) {
        let token = try await apiClient.login(username: username) { [cryptoService] challenge in
            if let expectedUserId, challenge.userId != expectedUserId {
                throw AuthError.userIdMismatch
            }
            guard cryptoService.hasIdentity(forUserId: challenge.userId) else {
                throw AuthError.noLocalIdentityForAccount
            }
            try cryptoService.loadIdentityFromKeychain(userId: challenge.userId)
            return try cryptoService.signChallenge(challenge, expectedUserId: challenge.userId)
        }
        if let expectedUserId, token.userId != expectedUserId { throw AuthError.userIdMismatch }
        guard cryptoService.hasIdentity(forUserId: token.userId) else {
            throw AuthError.noLocalIdentityForAccount
        }
        let canonical = await canonicalUsername(userId: token.userId, fallback: username, bearer: token.token)
        return (token, canonical)
    }

    /// The server's spelling of the username (best effort).
    private func canonicalUsername(userId: String, fallback: String, bearer: String? = nil) async -> String {
        if let bearer { try? tokenStore.save(bearer) }
        guard let entry = try? await apiClient.fetchDirectoryEntry(userId: userId), entry.userId == userId else {
            return fallback
        }
        return entry.username
    }

    func adoptRecoveredSession(token: AuthToken, username: String, bundle: PreKeyBundleUpload) throws {
        guard token.userId == bundle.userId else { throw AuthError.userIdMismatch }
        remember(username: username, userId: token.userId)
        try establishSession(token: token, username: username, bundle: bundle)
    }

    private func establishSession(token: AuthToken, username: String, bundle: PreKeyBundleUpload) throws {
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
        try tokenStore.save(token.token)

        currentUserId = token.userId
        currentUsername = username
        isStorageUnlocked = true
    }

    /// Clears in-memory secrets, the session pointer and the bearer token — never
    /// key material.
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
        tokenStore.clear()
    }

    /// After account deletion: also forget the username → id mapping.
    func forgetAccount(userId: String) {
        forget(userId: userId)
    }
}

enum AuthError: LocalizedError {
    case noLocalIdentityForAccount
    case userIdMismatch

    var errorDescription: String? {
        switch self {
        case .noLocalIdentityForAccount:
            return "This device has no keys for that account. Use “Restore account” to bring them over from a backup."
        case .userIdMismatch:
            return "The server asked this device to sign in to a different account. Sign-in was stopped."
        }
    }
}
