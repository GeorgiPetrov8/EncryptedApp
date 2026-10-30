import Foundation
import Combine
import UIKit
import UniformTypeIdentifiers
import os

/// Opt-in notifications through the free ntfy app — the app's only push
/// channel (no paid Apple account).
///
/// FIX (S36): the topic works like a password (anyone who knows it sees *when*
/// you get messages). It was kept in `UserDefaults` — part of every iCloud /
/// Finder backup and readable from an unencrypted one — and "Copy" put it on the
/// general pasteboard, which Universal Clipboard syncs to your other devices and
/// any app can read later. Now:
///   - stored in the Keychain (`WhenUnlockedThisDeviceOnly`, never in backups);
///     an old value in `UserDefaults` is moved over once and deleted;
///   - copied as local-only with a 2-minute expiry.
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
    private let keychain = KeychainStore(service: "com.HyperChat.ntfy")
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "ntfy")

    static let ntfyServer = "https://ntfy.sh"
    static let appStoreURL = URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!

    init(
        tokenStore: SessionTokenStore,
        authService: AuthService,
        baseURL: URL = NetworkConfiguration.baseURL,
        session: URLSession = NetworkConfiguration.apiSession,
        defaults: UserDefaults = .standard
    ) {
        self.tokenStore = tokenStore
        self.authService = authService
        self.baseURL = baseURL
        self.session = session
        self.defaults = defaults
    }

    // MARK: Storage

    private func legacyKey(_ userId: String) -> String { "ntfy.topic.\(userId)" }
    private func keychainKey(_ userId: String) -> String { KeychainStore.namespaced("ntfyTopic", userId: userId) }

    private func storedTopic(for userId: String) -> String? {
        if let data = keychain.loadIfPresent(key: keychainKey(userId)) {
            return String(data: data, encoding: .utf8)
        }
        // One-time migration from UserDefaults.
        if let legacy = defaults.string(forKey: legacyKey(userId)) {
            try? keychain.save(key: keychainKey(userId), data: Data(legacy.utf8))
            defaults.removeObject(forKey: legacyKey(userId))
            return legacy
        }
        return nil
    }

    private func storeTopic(_ topic: String?, for userId: String) {
        defaults.removeObject(forKey: legacyKey(userId))
        if let topic {
            try? keychain.save(key: keychainKey(userId), data: Data(topic.utf8))
        } else {
            keychain.delete(key: keychainKey(userId))
        }
    }

    /// Account deletion.
    func deleteLocalData(ownerUserId: String) {
        storeTopic(nil, for: ownerUserId)
        if authService.currentUserId == ownerUserId { topic = nil }
    }

    // MARK: Lifecycle

    func signedIn() async {
        guard let userId = authService.currentUserId else { return }
        topic = storedTopic(for: userId)
        guard let topic else { return }
        try? await upload(topic)
    }

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
        let newTopic = storedTopic(for: userId) ?? Self.generateTopic()
        try await upload(newTopic)
        storeTopic(newTopic, for: userId)
        topic = newTopic
    }

    func disable() async throws {
        guard let userId = authService.currentUserId else { throw APIError.notAuthenticated }
        isBusy = true
        defer { isBusy = false }
        try await send(path: "/devices/ntfy", body: ["topic": nil])
        storeTopic(nil, for: userId)
        topic = nil
    }

    func regenerate() async throws {
        guard let userId = authService.currentUserId else { throw APIError.notAuthenticated }
        isBusy = true
        defer { isBusy = false }
        let newTopic = Self.generateTopic()
        try await upload(newTopic)
        storeTopic(newTopic, for: userId)
        topic = newTopic
    }

    func sendTest() async throws {
        isBusy = true
        defer { isBusy = false }
        try await send(path: "/devices/ntfy/test", body: [String: String?]())
    }

    /// Local-only (no Universal Clipboard), cleared after 2 minutes.
    func copyTopic() {
        guard let topic else { return }
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: topic]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
    }

    func openAppStore() {
        UIApplication.shared.open(Self.appStoreURL)
    }

    // MARK: Helpers

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
            if http.statusCode == 401 {
                NotificationCenter.default.post(name: .sessionRejectedByServer, object: nil)
            }
            struct ErrorBody: Decodable { let message: String? }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
            throw NetworkError.server(status: http.statusCode, code: "ntfy", message: message ?? "HTTP \(http.statusCode)")
        }
    }

    private func makeRequest(path: String, method: String, bearer: String, body: [String: String?]) -> URLRequest {
        let url = URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let object: [String: Any] = body.mapValues { value in value.map { $0 as Any } ?? NSNull() }
        request.httpBody = try? JSONSerialization.data(withJSONObject: object)
        return request
    }
}
