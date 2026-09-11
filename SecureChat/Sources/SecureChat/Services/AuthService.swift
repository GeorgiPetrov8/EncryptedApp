import Foundation
import Combine
import os

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var currentUserId: String?
    @Published private(set) var currentUsername: String?

    /// Whether the at-rest key is available (see `unlockStorage()`).
    @Published private(set) var isStorageUnlocked = false

    private let cryptoService: CryptoService
    private let apiClient: APIClientProtocol
    private let userRepository: UserRepository
    private let keychain = KeychainStore(service: "com.securechat.session")
    private let logger = Logger(subsystem: "com.securechat", category: "auth")

    /// FIX: the handler now receives the account being logged out.
    ///
    /// It previously took no arguments and read `currentUserId` from the outside,
    /// which only worked because `logout()` happened to clear that property *after*
    /// invoking it — an ordering dependency with nothing enforcing it. Now that the
    /// handler has to evict one specific account's media cache rather than wiping the
    /// shared directory, passing the id explicitly removes the trap.
    private var onLogout: ((String) -> Void)?

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

        do {
            // Identity keys are not user-presence gated, so this is safe in init.
            // The storage key deliberately is not touched here — see `unlockStorage()`.
            try cryptoService.loadIdentityFromKeychain(userId: userId)
            currentUserId = userId
            currentUsername = username
            isStorageUnlocked = false
        } catch {
            logger.error("Session restore failed; keeping the user signed out")
        }
    }

    /// Completes a restored session by unlocking the at-rest key.
    ///
    /// Can't live in `restoreSessionIfPossible`: that runs synchronously inside `init`,
    /// during `AppContainer.bootstrap()`, so reading a `.userPresence`-gated Keychain
    /// item there would block app launch on a biometric sheet.
    ///
    /// Idempotent, and safe to call from more than one place — `RootView` calls it on
    /// cold launch, `AppLockView` calls it after a successful unlock. Callers must
    /// still avoid racing it against another biometric prompt; see `RootView`.
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

        // The self-row is owned by this account like any other contact.
        try userRepository.upsert(User(
            ownerUserId: token.userId,
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
        isStorageUnlocked = true // generation just created and cached the key
    }

    /// Loads the identity belonging to the account being signed into (Bug #10).
    func login(username: String) async throws {
        let token = try await apiClient.login(username: username)

        guard cryptoService.hasIdentity(forUserId: token.userId) else {
            throw AuthError.noLocalIdentityForAccount
        }

        try cryptoService.loadIdentityFromKeychain(userId: token.userId)
        // Surface the biometric prompt here rather than at the first message render.
        try cryptoService.unlockStorageKey()

        try keychain.save(key: Keys.userId, data: Data(token.userId.utf8))
        try keychain.save(key: Keys.username, data: Data(username.utf8))

        currentUserId = token.userId
        currentUsername = username
        isStorageUnlocked = true
    }

    /// Clears in-memory secrets and the session pointer, but never deletes key
    /// material — logging out must not destroy history (Bug #10).
    func logout() {
        // Capture before clearing: the handler needs to know whose cache to evict.
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
