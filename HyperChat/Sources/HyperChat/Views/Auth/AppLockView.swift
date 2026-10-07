import SwiftUI
import LocalAuthentication

/// The lock screen shown when App Lock is engaged.
///
/// This view carries more weight after Bug #6 than it did before. With the password
/// removed, biometrics/passcode is the *only* thing standing between someone holding
/// an unlocked device and the message history.
///
/// It also owns the biometric prompt while it is showing: `RootView` defers its
/// `unlockStorage()` call so the two never compete for the sensor.
struct AppLockView: View {
    @EnvironmentObject private var container: AppContainer

    private enum LockState: Equatable {
        case idle
        case authenticating
        case cancelled
        case failed
        case unavailable
    }

    @State private var state: LockState = .idle
    @State private var showLogoutConfirmation = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: iconName)
                .font(.system(size: 56))
                .foregroundStyle(state == .unavailable ? .orange : Color.brand)

            Text("HyperChat is locked")
                .font(.title2.bold())

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(state == .failed || state == .unavailable ? .red : .secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                Task { await attemptUnlock() }
            } label: {
                if state == .authenticating {
                    ProgressView()
                        .frame(maxWidth: 200)
                } else {
                    Text(state == .idle ? "Unlock" : "Try Again")
                        .frame(maxWidth: 200)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(state == .authenticating)

            // An escape hatch: a device that can't evaluate the policy would otherwise
            // strand the user here with no way to reach Settings or switch accounts.
            // Safe to expose, because logout clears in-memory secrets but never
            // deletes key material (Bug #10).
            if state == .failed || state == .unavailable || state == .cancelled {
                Button("Log Out Instead") {
                    showLogoutConfirmation = true
                }
                .font(.footnote)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task {
            // Only prompt automatically on first appearance. Re-prompting after a
            // cancel produces a loop the user can't break out of.
            guard state == .idle else { return }
            await attemptUnlock()
        }
        .confirmationDialog(
            "Log out of HyperChat?",
            isPresented: $showLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) {
                container.authService.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your messages and keys stay on this device. You can sign back in with your username.")
        }
    }

    private func attemptUnlock() async {
        // Distinguish "no biometrics enrolled" before attempting, so the user is told
        // what's actually wrong instead of a generic failure.
        guard Self.canAuthenticate() else {
            state = .unavailable
            return
        }

        state = .authenticating
        let success = await container.appLockService.unlock()
        guard success else {
            // LAContext doesn't cleanly separate "cancelled" from "failed" through
            // `AppLockService`'s Bool return, so this is presented as the softer of
            // the two — a genuine mismatch simply gets retried.
            state = .cancelled
            return
        }

        state = .idle

        // FIX: unlock the storage key here, sequentially, now that the screen is clear.
        //
        // `RootView.task` used to do this concurrently with the prompt above, so a cold
        // launch with App Lock enabled fired two biometric requests at once. Doing it
        // after a successful unlock means at most one sheet is ever on screen, and the
        // storage key is ready before any message row renders.
        //
        // The device has just authenticated, so the `.userPresence` Keychain read
        // typically resolves without a second prompt inside the system's grace window.
        await container.authService.unlockStorage()
    }

    private static func canAuthenticate() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    private var iconName: String {
        switch state {
        case .unavailable: return "exclamationmark.lock.fill"
        case .failed: return "lock.trianglebadge.exclamationmark"
        default: return "faceid"
        }
    }

    private var message: String? {
        switch state {
        case .idle, .authenticating:
            return nil
        case .cancelled:
            return "Authentication was cancelled."
        case .failed:
            return "Authentication failed."
        case .unavailable:
            return "This device has no passcode or biometrics set up, so HyperChat can't unlock. Set a device passcode in Settings, or turn off App Lock after logging back in."
        }
    }
}
