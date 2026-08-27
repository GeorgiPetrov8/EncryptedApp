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
            wrappedValue: AuthViewModel(authService: container.authService, messagingService: container.messagingService)
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
