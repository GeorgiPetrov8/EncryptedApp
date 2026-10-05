import Foundation
import UIKit
import UserNotifications
import os

/// Registers this device for push notifications and tells the server.
///
/// Push is what makes a message show up while HyperChat is closed. The
/// notification itself is generic ("New message") — the server can't see
/// message contents, and that's the point.
@MainActor
final class PushService {
    private let apiClient: APIClientProtocol
    private let authService: AuthService
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.HyperChat", category: "push")

    private enum Keys {
        static let token = "push.deviceToken"
    }

    /// Debug builds run from Xcode talk to Apple's sandbox; TestFlight and
    /// App Store builds use production. Sending to the wrong one fails with
    /// `BadDeviceToken`.
    private static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    init(apiClient: APIClientProtocol, authService: AuthService, defaults: UserDefaults = .standard) {
        self.apiClient = apiClient
        self.authService = authService
        self.defaults = defaults
    }

    var deviceToken: String? { defaults.string(forKey: Keys.token) }

    /// Asks for permission (no-op if already decided) and registers with APNs.
    /// The token arrives later in `AppDelegate`.
    func register() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: Keys.token)
        Task { await upload() }
    }

    /// Sends the token to the server. Called on registration and after sign-in.
    func upload() async {
        guard authService.isAuthenticated, let token = deviceToken else { return }
        do {
            try await apiClient.registerPushToken(token, environment: Self.environment)
        } catch {
            logger.error("Couldn't register the push token; will retry next launch")
        }
    }

    /// On logout: stop this phone getting the signed-out account's pushes.
    /// `bearer` is captured before the session token is cleared.
    func unregister(bearer: String?) {
        guard let bearer, let token = deviceToken else { return }
        let apiClient = self.apiClient
        Task { try? await apiClient.removePushToken(token, bearer: bearer) }
    }
}
