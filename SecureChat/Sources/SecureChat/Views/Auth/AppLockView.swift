import SwiftUI
import LocalAuthentication

/// The lock screen shown when App Lock is engaged.
///
/// This view carries more weight after Bug #6 than it did before. With the password
/// removed, biometrics/passcode is the *only* thing standing between someone holding
/// an unlocked device and the message history — so the failure paths here need to be
/// honest rather than decorative.
struct AppLockView: View {
    @EnvironmentObject private var container: AppContainer

    /// FIX: the original tracked a single `failedOnce` Bool, which conflated three
    /// very different outcomes — the user cancelled, authentication genuinely failed,
    /// and no biometrics/passcode is enrolled at all. The last case is the important
    /// one: `AppLockService.unlock()` fails closed when
    /// `canEvaluatePolicy` is false, so on such a device the old view showed
    /// "Authentication failed. Try again." forever and the app was unusable with no
    /// explanation and no way out.
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
                .foregroundStyle(state == .unavailable ? .orange : .tint)

            Text("SecureChat is locked")
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

            // FIX: an escape hatch.
            //
            // Previously a device that couldn't evaluate the policy — no passcode set,
            // biometrics locked out after repeated failures, a Simulator without
            // enrolment — left the user permanently stuck on this screen with no way
            // to reach Settings or switch accounts.
            //
            // Logging out is safe to expose here: it clears in-memory secrets and the
            // session pointer but never deletes key material (Bug #10), so the history
            // is still there after signing back in.
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
            // cancel produces a loop the user can't break out of, because dismissing
            // the system sheet re-triggers `.task` on some transitions.
            guard state == .idle else { return }
            await attemptUnlock()
        }
        .confirmationDialog(
            "Log out of SecureChat?",
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
        // FIX: distinguish "no biometrics enrolled" before attempting, so the user is
        // told what's actually wrong instead of being shown a generic failure.
        guard Self.canAuthenticate() else {
            state = .unavailable
            return
        }

        state = .authenticating
        let success = await container.appLockService.unlock()
        if success {
            state = .idle
        } else {
            // LAContext doesn't cleanly separate "cancelled" from "failed" through
            // `AppLockService`'s Bool return, so this is presented as the softer of
            // the two — a genuine mismatch simply gets retried.
            state = .cancelled
        }
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
            return "This device has no passcode or biometrics set up, so SecureChat can't unlock. Set a device passcode in Settings, or turn off App Lock after logging back in."
        }
    }
}
