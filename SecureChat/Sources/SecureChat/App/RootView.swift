import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        Group {
            if !container.authService.isAuthenticated {
                AuthContainerView(container: container)
            } else if container.appLockService.isEnabled && container.appLockService.isLocked {
                AppLockView()
            } else {
                ConversationListView(container: container)
            }
        }
        .animation(.default, value: container.authService.isAuthenticated)
        // FIX (Bug #24): opaque cover while the app is not active.
        //
        // Applied at the root, above every screen, so the app-switcher snapshot shows
        // the lock screen rather than whatever conversation was open. It is not
        // conditional on App Lock being enabled — the snapshot leaks message content
        // either way.
        .overlay {
            if container.appLockService.isObscured {
                PrivacyOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: container.appLockService.isObscured)
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
                Text("SecureChat")
                    .font(.title2.bold())
            }
        }
        .accessibilityHidden(true)
    }
}

/// Owns the single `AuthViewModel` shared by the login/register toggle.
/// Takes `container` as an explicit init parameter (rather than reading it
/// via @EnvironmentObject) because it needs it *before* `body` runs, to
/// construct the `@StateObject` — environment values aren't available at
/// init time in SwiftUI.
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
