import Foundation
import LocalAuthentication
import Combine

@MainActor
final class AppLockService: ObservableObject {
    @Published var isLocked: Bool
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    /// Minutes of inactivity before re-locking. 0 = lock immediately on background.
    @Published var autoLockMinutes: Double {
        didSet { UserDefaults.standard.set(autoLockMinutes, forKey: Keys.minutes) }
    }

    /// FIX (Bug #24): drives the privacy overlay.
    ///
    /// iOS captures the app-switcher snapshot on the transition to `.inactive`, which
    /// happens *before* `.background`. The old code only handled `.background`, so by
    /// the time anything reacted the screenshot of the open conversation had already
    /// been taken — and it persists in the switcher even with App Lock enabled.
    ///
    /// This is deliberately independent of `isEnabled`: the snapshot leaks message
    /// content regardless of whether the user opted into biometric locking.
    @Published private(set) var isObscured = false

    private var backgroundedAt: Date?

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

    /// FIX (Bug #24): called on `.inactive`, before the snapshot is taken.
    func appWillResignActive() {
        isObscured = true
    }

    func appDidEnterBackground() {
        isObscured = true
        backgroundedAt = Date()
    }

    func appWillEnterForeground() {
        defer {
            // Only reveal content once we're certain it isn't about to be locked.
            // If App Lock engages, `AppLockView` covers the screen anyway and the
            // overlay is redundant.
            isObscured = false
        }
        guard isEnabled else { return }
        guard let backgroundedAt else { return }
        let elapsedMinutes = Date().timeIntervalSince(backgroundedAt) / 60
        if elapsedMinutes >= autoLockMinutes {
            isLocked = true
        }
    }

    func unlock() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics/passcode configured on this device/simulator —
            // fail closed rather than silently unlocking.
            return false
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock HyperChat"
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
