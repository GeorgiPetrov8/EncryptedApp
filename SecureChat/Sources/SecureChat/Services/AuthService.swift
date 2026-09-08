import Foundation
import Combine
import os

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var currentUserId: String?
    @Published private(set) var currentUsername: String?

    private let cryptoService: CryptoService
    private let apiClient: APIClientProtocol
    private let userRepository: UserRepository
    private let keychain = KeychainStore(service: "com.securechat.session")
    private let logger = Logger(subsystem: "com.securechat", category: "auth")

    /// FIX (Bug #23): logout must clear cached attachments, otherwise one account's
    /// media files stay on disk for whoever signs in next.
    private var onLogout: (() -> Void)?

    private enum Keys {
        static let userId = "sessionUserId"
        static let username = "sessionUsername"
    }

    var isAuthenticated: Bool { currentUserId != nil }

    init(cryptoService: CryptoService, apiClient: APIClientProtocol, userRepository: UserRepository) {
        self.cryptoService = cryptoService
        self.apiClient = apiClient
        self.userRepository = userRepository
        restoreSessionIfPossible()
    }

    /// Injected by `AppContainer` after construction, since the media service depends
    /// on repositories that are built alongside this one.
    func setLogoutHandler(_ handler: @escaping () -> Void) {
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

        do {
            try cryptoService.loadIdentityFromKeychain(userId: userId)
            currentUserId = userId
            currentUsername = username
        } catch {
            logger.error("Session restore failed; keeping the user signed out")
        }
    }

    /// Registers a brand-new account. Identity and prekeys are generated on this
    /// device and only the public bundle is published (Bug #6: no password).
    func register(username: String) async throws {
        let userId = UUID().uuidString

        // FIX (Bug #11): the username is published as part of the bundle, so peers
        // can resolve a display name from a user id alone.
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
            id: token.userId,
            username: username,
            publicKey: bundle.identityAgreementKey,
            createdAt: Date(),
            identitySigningKey: bundle.identitySigningKey,
            isVerified: true // our own identity is trivially "verified"
        ))

        try keychain.save(key: Keys.userId, data: Data(token.userId.utf8))
        try keychain.save(key: Keys.username, data: Data(username.utf8))

        currentUserId = token.userId
        currentUsername = username
    }

    /// Loads the identity belonging to the account being signed into (Bug #10).
    func login(username: String) async throws {
        let token = try await apiClient.login(username: username)

        guard cryptoService.hasIdentity(forUserId: token.userId) else {
            // Keys live only on the device that registered them; this mock backend
            // doesn't model multi-device restore.
            throw AuthError.noLocalIdentityForAccount
        }

        try cryptoService.loadIdentityFromKeychain(userId: token.userId)
        // Surface the biometric prompt here rather than at the first message render.
        try cryptoService.unlockStorageKey()

        try keychain.save(key: Keys.userId, data: Data(token.userId.utf8))
        try keychain.save(key: Keys.username, data: Data(username.utf8))

        currentUserId = token.userId
        currentUsername = username
    }

    /// Clears in-memory secrets and the session pointer, but never deletes key
    /// material — logging out must not destroy history (Bug #10).
    func logout() {
        cryptoService.deactivate()
        onLogout?()
        currentUserId = nil
        currentUsername = nil
        keychain.delete(key: Keys.userId)
        keychain.delete(key: Keys.username)
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
