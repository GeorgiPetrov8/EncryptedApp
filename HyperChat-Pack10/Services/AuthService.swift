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
    private let logger = Logger(subsystem: "com.HyperChat", category: "auth")

    /// The server-issued bearer token, shared with the network layer.
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

        try establishSession(token: token, username: username, bundle: bundle)
    }

    /// Signs in to an account whose keys are already on this device.
    func login(username: String) async throws {
        let token = try await apiClient.login(username: username)

        guard cryptoService.hasIdentity(forUserId: token.userId) else {
            throw AuthError.noLocalIdentityForAccount
        }

        try cryptoService.loadIdentityFromKeychain(userId: token.userId)
        try cryptoService.unlockStorageKey()

        try keychain.save(key: Keys.userId, data: Data(token.userId.utf8))
        try keychain.save(key: Keys.username, data: Data(username.utf8))
        try tokenStore.save(token.token)

        currentUserId = token.userId
        currentUsername = username
        isStorageUnlocked = true
    }

    /// Completes recovery-by-email: the server has accepted brand-new keys for
    /// this username and issued a token. Same final steps as registration.
    func adoptRecoveredSession(token: AuthToken, username: String, bundle: PreKeyBundleUpload) throws {
        guard token.userId == bundle.userId else { throw AuthError.userIdMismatch }
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

    /// Clears in-memory secrets, the session pointer and the bearer token —
    /// but never deletes key material (Bug #10).
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
}

enum AuthError: LocalizedError {
    case noLocalIdentityForAccount
    case userIdMismatch

    var errorDescription: String? {
        switch self {
        case .noLocalIdentityForAccount:
            return "This device has no keys for that account. Use “Restore account” to bring them over from a backup."
        case .userIdMismatch:
            return "The server returned an unexpected account id."
        }
    }
}
