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

    /// Drives the privacy overlay (Bug #24).
    ///
    /// iOS captures the app-switcher snapshot on the transition to `.inactive`, which
    /// happens *before* `.background`, so the overlay has to appear then.
    ///
    /// Deliberately independent of `isEnabled`: the snapshot leaks message content
    /// regardless of whether the user opted into biometric locking.
    @Published private(set) var isObscured = false

    /// When the app actually went to the background. Cleared as soon as it has been
    /// consulted — see `appWillEnterForeground`.
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

    /// Called on `.inactive`, before the snapshot is taken.
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
            // If App Lock engages, `AppLockView` covers the screen anyway.
            isObscured = false
        }
        guard isEnabled else { return }

        // FIX: this timestamp was never cleared.
        //
        // The scene goes `.inactive` -> `.active` — without ever reaching
        // `.background` — when Control Center, a notification banner or a system
        // alert is pulled down. The `.active` handler then compared "now" with a
        // `backgroundedAt` left over from the *previous* real backgrounding and
        // locked the app in the middle of typing. A timestamp is only meaningful
        // for the one return that follows the background that set it.
        guard let leftAt = backgroundedAt else { return }
        backgroundedAt = nil

        let elapsedMinutes = Date().timeIntervalSince(leftAt) / 60
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
