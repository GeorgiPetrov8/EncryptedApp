import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: AppContainer

    /// FIX: whether App Lock is currently covering the screen.
    ///
    /// Extracted so both the branch selection and the unlock guard read the same
    /// condition, rather than expressing it twice and risking drift.
    private var isAppLockBlocking: Bool {
        container.appLockService.isEnabled && container.appLockService.isLocked
    }

    var body: some View {
        Group {
            if !container.authService.isAuthenticated {
                AuthContainerView(container: container)
            } else if isAppLockBlocking {
                AppLockView()
            } else {
                ConversationListView(container: container)
            }
        }
        .animation(.default, value: container.authService.isAuthenticated)
        // Opaque cover while the app is not active (Bug #24).
        .overlay {
            if container.appLockService.isObscured {
                PrivacyOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: container.appLockService.isObscured)
        // FIX: don't race AppLockView for the biometric sensor.
        //
        // This `.task` is attached to the outer `Group`, so it runs regardless of which
        // branch is showing. On a cold launch with App Lock enabled, that meant two
        // concurrent authentication requests: this one reading the `.userPresence`
        // Keychain item, and `AppLockView.task` calling `LAContext.evaluatePolicy`.
        // iOS serialises or drops the overlapping sheets, and whichever loses leaves
        // `isStorageUnlocked == false` — with no second chance, because a `.task`
        // fires once per view lifetime. The "prompt once, up front" intent this was
        // written for failed in exactly the configuration it was written for.
        //
        // The guard defers to `AppLockView`, which owns the prompt while it is
        // showing and calls `unlockStorage()` itself once the user is through.
        .task(id: isAppLockBlocking) {
            guard container.authService.isAuthenticated,
                  !container.authService.isStorageUnlocked,
                  !isAppLockBlocking else { return }
            await container.authService.unlockStorage()
        }
    }
}

/// Deliberately opaque rather than blurred: a blur of a chat transcript can still
/// leak message shape, sender colours and rough length.
private struct PrivacyOverlay: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("HyperChat")
                    .font(.title2.bold())
            }
        }
        .accessibilityHidden(true)
    }
}

/// Owns the single `AuthViewModel` shared by the login/register toggle.
/// Takes `container` as an explicit init parameter because it needs it *before*
/// `body` runs, to construct the `@StateObject`.
private struct AuthContainerView: View {
    @StateObject private var viewModel: AuthViewModel
    @State private var showRegister = false

    init(container: AppContainer) {
        _viewModel = StateObject(
            wrappedValue: AuthViewModel(authService: container.authService)
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if showRegister {
                    RegisterView(viewModel: viewModel)
                } else {
                    LoginView(viewModel: viewModel)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(showRegister ? "Have an account?" : "Create account") {
                        viewModel.errorMessage = nil
                        showRegister.toggle()
                    }
                }
            }
        }
    }
}
