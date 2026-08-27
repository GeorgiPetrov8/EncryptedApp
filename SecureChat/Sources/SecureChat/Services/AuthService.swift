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
    /// device and only the public bundle is published.
    ///
    /// FIX (Bug #6): no password parameter.
    ///
    /// The previous signature took one, derived a PBKDF2 key from it, and threw the
    /// result away with `_ =`. `login` ignored it entirely and `MockBackendStore`
    /// resolved accounts by username alone — so the credential fields in the UI
    /// promised a protection that did not exist anywhere in the codebase.
    ///
    /// Local secrecy is now enforced by the platform instead: the storage key is
    /// stored under `.userPresence` access control (Face ID / Touch ID / passcode)
    /// and `AppLockService` gates the UI. That is stronger than a user-chosen
    /// password, cannot be forgotten, and adds no hand-rolled crypto.
    func register(username: String) async throws {
        let userId = UUID().uuidString

        // FIX (Bug #10): `force` is deliberately not set — generating over existing
        // key material is what destroyed the first account's history.
        let bundle = try cryptoService.generateIdentityAndBundle(userId: userId)

        let token: AuthToken
        do {
            token = try await apiClient.register(username: username, bundle: bundle)
        } catch {
            // The account never came into existence server-side, so don't leave
            // orphaned key material behind.
            cryptoService.deleteAccount(userId: userId)
            throw error
        }

        // The server assigns the authoritative id; re-bind if it differs.
        if token.userId != userId {
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

    /// FIX (Bug #10): the identity loaded is now the one belonging to the account
    /// being signed into.
    ///
    /// The old implementation checked a *global* `hasIdentity` and then called
    /// `loadIdentityFromKeychain()` with no account context. Registering as Alice,
    /// logging out and logging in as Bob therefore loaded **Alice's** identity keys
    /// under Bob's session — signing with her key and decrypting her sessions. That
    /// is an identity compromise, not just the data loss the ticket described.
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

    /// FIX (Bug #10): clears in-memory secrets and the session pointer, but never
    /// deletes key material — logging out must not destroy history.
    func logout() {
        cryptoService.deactivate()
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
