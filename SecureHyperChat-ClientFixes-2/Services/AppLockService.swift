import Foundation
import LocalAuthentication
import Combine

@MainActor
final class AppLockService: ObservableObject {
    @Published var isLocked: Bool
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    @Published var autoLockMinutes: Double {
        didSet { UserDefaults.standard.set(autoLockMinutes, forKey: Keys.minutes) }
    }

    /// Drives the privacy overlay (Bug #24). Independent of `isEnabled`.
    @Published private(set) var isObscured = false

    /// FIX (S22): measured with the system uptime clock, not `Date()`.
    ///
    /// `Date()` follows the clock the user can set in Settings: moving it back
    /// before returning to the app made the elapsed time negative and the lock
    /// never engaged. `systemUptime` only moves forward. If the phone was restarted
    /// in between (uptime smaller than when we left), that counts as "long enough".
    private var backgroundedAtUptime: TimeInterval?

    /// Called when the app actually locks, so decrypted content and the storage
    /// key can be dropped from memory (S23).
    var onLock: (() -> Void)?

    private enum Keys {
        static let enabled = "appLock.enabled"
        static let minutes = "appLock.autoLockMinutes"
    }

    init() {
        let enabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        isEnabled = enabled
        autoLockMinutes = UserDefaults.standard.object(forKey: Keys.minutes) as? Double ?? 1
        isLocked = enabled
    }

    func appWillResignActive() {
        isObscured = true
    }

    func appDidEnterBackground() {
        isObscured = true
        backgroundedAtUptime = ProcessInfo.processInfo.systemUptime
        DecryptedMediaCache.shared.removeAll()
    }

    func appWillEnterForeground() {
        defer { isObscured = false }
        guard isEnabled else { return }

        guard let leftAt = backgroundedAtUptime else { return }
        backgroundedAtUptime = nil

        let now = ProcessInfo.processInfo.systemUptime
        let elapsedMinutes = now >= leftAt ? (now - leftAt) / 60 : .infinity
        if elapsedMinutes >= autoLockMinutes {
            lock()
        }
    }

    func lock() {
        guard isEnabled else { return }
        isLocked = true
        onLock?()
    }

    func unlock() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock SecureHyperChat"
            )
            if success {
                isLocked = false
                isObscured = false
            }
            return success
        } catch {
            return false
        }
    }
}
