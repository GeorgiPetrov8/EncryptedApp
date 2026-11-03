import Foundation
import UIKit
import Combine

/// #9: share your battery percentage with your contacts. **Off by default.**
///
/// What it costs in privacy: the server (and Cloudflare in front of it) sees the
/// level — it's relayed like the online dot, not end-to-end encrypted. It's kept
/// only in the server's memory, never in the database, and cleared when you go
/// offline or switch sharing off.
///
/// Sent when the level moves by 5 points or more, or charging starts/stops —
/// not on every 1 %. Contacts see it only while you're online, only if you're
/// mutual contacts, and never while "Show when I'm online" is off.
@MainActor
final class BatteryShareService: ObservableObject {
    struct Reading: Equatable {
        let level: Int
        let charging: Bool
        let at: Date

        /// Older readings are hidden (the phone may have slept since).
        var isFresh: Bool { Date().timeIntervalSince(at) < 30 * 60 }
    }

    @Published var isSharing: Bool {
        didSet {
            UserDefaults.standard.set(isSharing, forKey: Keys.sharing)
            isSharing ? start() : stop()
        }
    }
    @Published private(set) var peers: [String: Reading] = [:]

    private let webSocket: WebSocketServiceProtocol
    private var lastSent: (level: Int, charging: Bool)?
    private var observers: [NSObjectProtocol] = []

    private static let threshold = 5

    private enum Keys {
        static let sharing = "battery.isSharing"
    }

    init(webSocket: WebSocketServiceProtocol) {
        self.webSocket = webSocket
        self.isSharing = UserDefaults.standard.bool(forKey: Keys.sharing) // default false
    }

    func reading(for peerId: String) -> Reading? {
        guard let reading = peers[peerId], reading.isFresh else { return nil }
        return reading
    }

    // MARK: Lifecycle

    /// After every (re)connection: the server forgot us when the socket closed.
    func connected() {
        lastSent = nil
        if isSharing { sendIfNeeded(force: true) }
    }

    func activate() {
        if isSharing { start() }
    }

    private func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        if observers.isEmpty {
            let center = NotificationCenter.default
            for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.sendIfNeeded(force: false) }
                })
            }
        }
        sendIfNeeded(force: true)
    }

    private func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = false
        lastSent = nil
        webSocket.sendEphemeral(.battery(level: nil, charging: false))
    }

    private func sendIfNeeded(force: Bool) {
        guard isSharing else { return }
        let raw = UIDevice.current.batteryLevel
        guard raw >= 0 else { return } // unknown (e.g. Simulator)
        let level = Int((raw * 100).rounded())
        let state = UIDevice.current.batteryState
        let charging = state == .charging || state == .full

        if !force, let lastSent,
           abs(lastSent.level - level) < Self.threshold,
           lastSent.charging == charging { return }
        lastSent = (level, charging)
        webSocket.sendEphemeral(.battery(level: level, charging: charging))
    }

    // MARK: Receiving

    func apply(from peerId: String, level: Int?, charging: Bool, at: Date) {
        if let level {
            peers[peerId] = Reading(level: level, charging: charging, at: at)
        } else {
            peers.removeValue(forKey: peerId)
        }
    }

    func reset() {
        peers.removeAll()
        lastSent = nil
    }
}
