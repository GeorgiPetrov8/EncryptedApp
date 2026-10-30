import Foundation
import Combine
import os

/// A local account this phone has keys for.
struct LocalAccount: Identifiable, Equatable {
    let userId: String
    let username: String
    var id: String { userId }
}

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var currentUserId: String?
    @Published private(set) var currentUsername: String?
    @Published private(set) var isStorageUnlocked = false
    /// NEW (R8): every account set up on this phone.
    @Published private(set) var localAccounts: [LocalAccount] = []

    private let cryptoService: CryptoService
    private let apiClient: APIClientProtocol
    private let userRepository: UserRepository
    private let keychain = KeychainStore(service: "com.HyperChat.session")
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "auth")
    private let tokenStore: SessionTokenStore

    /// `(departingUserId, keepServerSession)`. `keepServerSession` is true when
    /// switching accounts: the departing account stays signed in on the server
    /// (and keeps its ntfy notifications) so switching back is instant.
    private var onLogout: ((String, Bool) -> Void)?

    private enum Keys {
        static let userId = "sessionUserId"
        static let username = "sessionUsername"
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
        refreshLocalAccounts()
    }

    func setLogoutHandler(_ handler: @escaping (String, Bool) -> Void) {
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

        tokenStore.activate(userId: userId)
        guard tokenStore.currentToken != nil else {
            logger.error("Session restore found identity but no session token; requiring re-login")
            return
        }

        do {
            try cryptoService.loadIdentityFromKeychain(userId: userId)
            remember(username: username, userId: userId)
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

    func lockStorage() {
        isStorageUnlocked = false
    }

    // MARK: Known accounts

    private func knownAccounts() -> [String: String] {
        guard let data = keychain.loadIfPresent(key: Keys.knownAccounts),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    private func saveKnownAccounts(_ map: [String: String]) {
        if let data = try? JSONEncoder().encode(map) {
            try? keychain.save(key: Keys.knownAccounts, data: data)
        }
        refreshLocalAccounts()
    }

    private func remember(username: String, userId: String) {
        var map = knownAccounts().filter { $0.value != userId }
        map[username.lowercased()] = userId
        saveKnownAccounts(map)
    }

    func refreshLocalAccounts() {
        // The map is lowercased name → id; the display name is the stored one.
        localAccounts = knownAccounts()
            .filter { cryptoService.hasIdentity(forUserId: $0.value) }
            .map { entry in
                let name = (try? userRepository.fetch(ownerUserId: entry.value, id: entry.value))?.username ?? entry.key
                return LocalAccount(userId: entry.value, username: name)
            }
            .sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
    }

    /// After account deletion.
    func forgetAccount(userId: String) {
        saveKnownAccounts(knownAccounts().filter { $0.value != userId })
        tokenStore.removeAll(userId: userId)
    }

    // MARK: Register

    func register(username: String) async throws {
        let userId = UUID().uuidString
        let bundle = try cryptoService.generateIdentityAndBundle(userId: userId, username: username)

        let token: AuthToken
        do {
            token = try await apiClient.register(username: username, bundle: bundle)
        } catch {
            // R7: the server may have created the account and only the answer was lost.
            if let recovered = try? await signIn(username: username, expectedUserId: userId) {
                remember(username: recovered.username, userId: userId)
                try establishSession(token: recovered.token, username: recovered.username, bundle: bundle)
                return
            }
            cryptoService.deleteAccount(userId: userId)
            throw error
        }

        guard token.userId == userId else {
            cryptoService.deleteAccount(userId: userId)
            throw AuthError.userIdMismatch
        }

        remember(username: username, userId: userId)
        try establishSession(token: token, username: username, bundle: bundle)
    }

    // MARK: Login

    func login(username: String) async throws {
        let expected = knownAccounts()[username.lowercased()]
        let result = try await signIn(username: username, expectedUserId: expected)

        try cryptoService.loadIdentityFromKeychain(userId: result.token.userId)
        try cryptoService.unlockStorageKey()

        remember(username: result.username, userId: result.token.userId)
        try keychain.save(key: Keys.userId, data: Data(result.token.userId.utf8))
        try keychain.save(key: Keys.username, data: Data(result.username.utf8))
        tokenStore.activate(userId: result.token.userId)
        try tokenStore.save(result.token.token)

        currentUserId = result.token.userId
        currentUsername = result.username
        isStorageUnlocked = true
    }

    private func signIn(username: String, expectedUserId: String?) async throws -> (token: AuthToken, username: String) {
        let token = try await apiClient.login(username: username) { [cryptoService] challenge in
            if let expectedUserId, challenge.userId != expectedUserId { throw AuthError.userIdMismatch }
            guard cryptoService.hasIdentity(forUserId: challenge.userId) else {
                throw AuthError.noLocalIdentityForAccount
            }
            try cryptoService.loadIdentityFromKeychain(userId: challenge.userId)
            return try cryptoService.signChallenge(challenge, expectedUserId: challenge.userId)
        }
        if let expectedUserId, token.userId != expectedUserId { throw AuthError.userIdMismatch }
        guard cryptoService.hasIdentity(forUserId: token.userId) else { throw AuthError.noLocalIdentityForAccount }

        // The directory lookup needs this token, so it's stored for its own account.
        tokenStore.activate(userId: token.userId)
        try? tokenStore.save(token.token, for: token.userId)
        let canonical = await canonicalUsername(userId: token.userId, fallback: username)
        return (token, canonical)
    }

    private func canonicalUsername(userId: String, fallback: String) async -> String {
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
        tokenStore.activate(userId: token.userId)
        try tokenStore.save(token.token)

        currentUserId = token.userId
        currentUsername = username
        isStorageUnlocked = true
        refreshLocalAccounts()
    }

    // MARK: Switching accounts (R8)

    /// Switches to another account on this phone. Uses its saved session when
    /// there is one (no network needed; Face ID unlocks its storage), otherwise
    /// signs in with its keys.
    func switchAccount(to userId: String) async throws {
        guard userId != currentUserId else { return }
        guard let account = localAccounts.first(where: { $0.userId == userId }) else {
            throw AuthError.noLocalIdentityForAccount
        }
        endSession(keepServerSession: true)

        try cryptoService.loadIdentityFromKeychain(userId: userId)
        tokenStore.activate(userId: userId)

        guard tokenStore.currentToken != nil else {
            try await login(username: account.username)
            return
        }

        try keychain.save(key: Keys.userId, data: Data(userId.utf8))
        try keychain.save(key: Keys.username, data: Data(account.username.utf8))
        currentUserId = userId
        currentUsername = account.username
        isStorageUnlocked = false
        await unlockStorage()
    }

    /// "Add another account": leaves this one signed in on the server and shows
    /// the sign-in screen.
    func signOutForAnotherAccount() {
        endSession(keepServerSession: true)
    }

    /// Full logout of the current account. Its keys stay; its session ends.
    func logout() {
        endSession(keepServerSession: false)
    }

    private func endSession(keepServerSession: Bool) {
        let departingUserId = currentUserId
        cryptoService.deactivate()
        if let departingUserId {
            onLogout?(departingUserId, keepServerSession)
        }
        currentUserId = nil
        currentUsername = nil
        isStorageUnlocked = false
        keychain.delete(key: Keys.userId)
        keychain.delete(key: Keys.username)
        if keepServerSession {
            tokenStore.deactivate()
        } else {
            tokenStore.clear()
        }
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
