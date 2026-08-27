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

    func appDidEnterBackground() {
        backgroundedAt = Date()
    }

    func appWillEnterForeground() {
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
                localizedReason: "Unlock SecureChat"
            )
            if success { isLocked = false }
            return success
        } catch {
            return false
        }
    }
}
