import Foundation
import Combine
import os

extension Notification.Name {
    /// Posted when the server answers 401 to a request or refuses the WebSocket
    /// auth frame — the session token is no longer valid.
    static let sessionRejectedByServer = Notification.Name("SecureHyperChat.sessionRejectedByServer")
}

/// Keeps the server session alive without the user noticing.
///
/// The bearer token expires 30 days after login, whatever the user does, and the
/// app used to keep looking signed in while every request quietly failed. The
/// device still holds the identity key, so it can sign a fresh login challenge on
/// its own and get a new token.
///
/// When it renews:
///   - when the app opens / comes to the foreground, if the last renewal is older
///     than 24 hours (not on every open: each renewal is two requests against the
///     server's login rate limit);
///   - straight away when the server rejects the token (401, or WebSocket auth
///     refused), at most once a minute.
///
/// What happens on failure:
///   - no network, rate limited, server error: nothing — the old token stays and
///     the next open tries again;
///   - the account no longer exists, or the server has different keys for it
///     (it was recovered on another phone): the session is over, so the user is
///     logged out with an explanation. Keys and local data are kept, exactly as
///     with a normal logout.
@MainActor
final class SessionRenewalService: ObservableObject {
    /// Shown on the sign-in screen after the session had to be ended.
    @Published private(set) var endedMessage: String?

    static let renewAfter: TimeInterval = 24 * 60 * 60
    static let minimumForcedInterval: TimeInterval = 60

    private let authService: AuthService
    private let apiClient: APIClientProtocol
    private let cryptoService: CryptoService
    private let tokenStore: SessionTokenStore
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "session")

    private var inFlight: Task<Void, Never>?
    private var lastForcedAttempt = Date.distantPast
    private var observer: NSObjectProtocol?

    init(
        authService: AuthService,
        apiClient: APIClientProtocol,
        cryptoService: CryptoService,
        tokenStore: SessionTokenStore,
        defaults: UserDefaults = .standard
    ) {
        self.authService = authService
        self.apiClient = apiClient
        self.cryptoService = cryptoService
        self.tokenStore = tokenStore
        self.defaults = defaults

        observer = NotificationCenter.default.addObserver(
            forName: .sessionRejectedByServer, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.renew(force: true) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func renewedAtKey(_ userId: String) -> String { "session.renewedAt.\(userId)" }

    // MARK: Triggers

    /// Call when the scene becomes active.
    func appBecameActive() {
        renew(force: false)
    }

    /// Call right after a fresh login/registration, so the 24 h clock starts then.
    func markFresh() {
        guard let userId = authService.currentUserId else { return }
        defaults.set(Date(), forKey: renewedAtKey(userId))
        endedMessage = nil
    }

    func clearEndedMessage() {
        endedMessage = nil
    }

    func renew(force: Bool) {
        guard !NetworkConfiguration.useMockBackend,
              inFlight == nil,
              let userId = authService.currentUserId,
              let username = authService.currentUsername
        else { return }

        if force {
            guard Date().timeIntervalSince(lastForcedAttempt) >= Self.minimumForcedInterval else { return }
            lastForcedAttempt = Date()
        } else if let last = defaults.object(forKey: renewedAtKey(userId)) as? Date,
                  Date().timeIntervalSince(last) < Self.renewAfter {
            return
        }

        inFlight = Task { [weak self] in
            await self?.perform(userId: userId, username: username)
            self?.inFlight = nil
        }
    }

    // MARK: Renewal

    private func perform(userId: String, username: String) async {
        let oldToken = tokenStore.currentToken
        do {
            // `expectedUserId`: the server can't make this device sign for a
            // different local account than the one that is signed in.
            let token = try await apiClient.login(username: username) { [cryptoService] challenge in
                try cryptoService.signChallenge(challenge, expectedUserId: userId)
            }

            // The user may have logged out (or switched account) meanwhile.
            guard token.userId == userId, authService.currentUserId == userId else { return }

            try tokenStore.save(token.token)
            defaults.set(Date(), forKey: renewedAtKey(userId))
            // Requests still in flight with the old token will get 401 once it is
            // revoked below; this stops them from triggering a second renewal.
            lastForcedAttempt = Date()
            endedMessage = nil
            logger.info("Session renewed")

            // End the old session on the server. An open WebSocket that used it is
            // closed within one heartbeat and reconnects with the new token.
            if let oldToken, oldToken != token.token {
                Self.revoke(oldToken)
            }
        } catch {
            handle(error, userId: userId)
        }
    }

    private func handle(_ error: Error, userId: String) {
        if Self.meansSessionIsOver(error) {
            logger.error("Session can't be renewed; signing out")
            guard authService.currentUserId == userId else { return }
            endedMessage = "Your session ended. If you recovered this account on another phone, this phone's keys are no longer valid — use “Restore account” here."
            authService.logout()
        } else {
            // Offline, rate limited, server down: keep the current token.
            logger.info("Session renewal postponed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Only answers that can't get better by trying again later.
    private static func meansSessionIsOver(_ error: Error) -> Bool {
        if let apiError = error as? APIError, case .userNotFound = apiError { return true }
        if let authError = error as? AuthError, case .userIdMismatch = authError { return true }
        if let networkError = error as? NetworkError,
           case .server(let status, let code, _) = networkError,
           status == 401, code == "invalidSignature" {
            return true // the server holds different keys for this account
        }
        return false
    }

    private static func revoke(_ token: String) {
        guard let url = URL(string: "/auth/logout", relativeTo: NetworkConfiguration.baseURL)?.absoluteURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        Task.detached(priority: .utility) {
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
