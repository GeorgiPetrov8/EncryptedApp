import Foundation
import Combine
import UIKit
import os

/// Opt-in notifications through the free ntfy app, for builds without Apple
/// push (free developer account / SideStore).
///
/// Turning it on generates a random topic for this account and gives it to
/// the server. The user subscribes to that topic in the ntfy app; from then
/// on the server posts a generic "New message" there whenever something
/// arrives while HyperChat is closed. Message text never leaves the device.
///
/// The topic works like a password — anyone who knows it can read the
/// notifications (not the messages). It's 24 random characters, so it can't
/// be guessed; it can be regenerated at any time.
@MainActor
final class NtfyService: ObservableObject {

    @Published private(set) var topic: String?
    @Published private(set) var isBusy = false

    var isEnabled: Bool { topic != nil }

    private let tokenStore: SessionTokenStore
    private let authService: AuthService
    private let baseURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.HyperChat", category: "ntfy")

    /// The public ntfy server the iPhone app is subscribed to by default.
    static let ntfyServer = "https://ntfy.sh"
    static let appStoreURL = URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!

    init(
        tokenStore: SessionTokenStore,
        authService: AuthService,
        baseURL: URL = NetworkConfiguration.baseURL,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.tokenStore = tokenStore
        self.authService = authService
        self.baseURL = baseURL
        self.session = session
        self.defaults = defaults
    }

    private func key(_ userId: String) -> String { "ntfy.topic.\(userId)" }

    // MARK: Lifecycle

    /// After sign-in: show this account's setting and make sure the server
    /// has it (it's removed from the server on logout — see `signedOut`).
    func signedIn() async {
        guard let userId = authService.currentUserId else { return }
        topic = defaults.string(forKey: key(userId))
        guard let topic else { return }
        try? await upload(topic)
    }

    /// On logout: stop this phone getting the signed-out account's
    /// notifications. The topic is kept locally, so signing back in turns
    /// them on again without re-subscribing in ntfy.
    func signedOut(bearer: String?) {
        let wasEnabled = topic != nil
        topic = nil
        guard wasEnabled, let bearer else { return }
        let request = makeRequest(path: "/devices/ntfy", method: "POST", bearer: bearer, body: ["topic": nil])
        Task { [session] in _ = try? await session.data(for: request) }
    }

    // MARK: User actions

    func enable() async throws {
        guard let userId = authService.currentUserId else { throw APIError.notAuthenticated }
        isBusy = true
        defer { isBusy = false }
        let newTopic = defaults.string(forKey: key(userId)) ?? Self.generateTopic()
        try await upload(newTopic)
        defaults.set(newTopic, forKey: key(userId))
        topic = newTopic
    }

    func disable() async throws {
        guard let userId = authService.currentUserId else { throw APIError.notAuthenticated }
        isBusy = true
        defer { isBusy = false }
        try await send(path: "/devices/ntfy", body: ["topic": nil])
        defaults.removeObject(forKey: key(userId))
        topic = nil
    }

    /// New topic — if the old one was shared by mistake. The user has to
    /// subscribe to the new one in ntfy.
    func regenerate() async throws {
        guard let userId = authService.currentUserId else { throw APIError.notAuthenticated }
        isBusy = true
        defer { isBusy = false }
        let newTopic = Self.generateTopic()
        try await upload(newTopic)
        defaults.set(newTopic, forKey: key(userId))
        topic = newTopic
    }

    func sendTest() async throws {
        isBusy = true
        defer { isBusy = false }
        try await send(path: "/devices/ntfy/test", body: [String: String?]())
    }

    func copyTopic() {
        UIPasteboard.general.string = topic
    }

    func openAppStore() {
        UIApplication.shared.open(Self.appStoreURL)
    }

    // MARK: Helpers

    /// "hc-" + 24 random characters from a 32-letter alphabet ≈ 120 bits.
    static func generateTopic() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        let suffix = (0..<24).map { _ in alphabet.randomElement(using: &generator)! }
        return "hc-" + String(suffix)
    }

    private func upload(_ topic: String) async throws {
        try await send(path: "/devices/ntfy", body: ["topic": topic])
    }

    private func send(path: String, body: [String: String?]) async throws {
        guard let bearer = tokenStore.currentToken else { throw APIError.notAuthenticated }
        let request = makeRequest(path: path, method: "POST", bearer: bearer, body: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let message: String? }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
            throw NetworkError.server(status: http.statusCode, code: "ntfy", message: message ?? "HTTP \(http.statusCode)")
        }
    }

    private func makeRequest(path: String, method: String, bearer: String, body: [String: String?]) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // JSONSerialization keeps `nil` as JSON null, which the server reads as "off".
        let object: [String: Any] = body.mapValues { value in value.map { $0 as Any } ?? NSNull() }
        request.httpBody = try? JSONSerialization.data(withJSONObject: object)
        return request
    }
}
