import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: AppContainer

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
        // FIX (alarm): the ringing challenge sits above every normal screen,
        // including the app lock.
        //
        // Above the app lock on purpose: silencing an alarm shouldn't
        // require Face ID. The maths challenge touches no encrypted data,
        // so there's nothing to protect — and forcing authentication first
        // would mean fumbling biometrics half-asleep before you can even
        // start. The one case that genuinely needs the storage key unlocked
        // is the message mode, and `AlarmRingingView` prompts for that
        // itself, at the point it actually matters.
        //
        // An overlay rather than a `.sheet` because sheets are
        // interactively dismissible by default, and a downward swipe is
        // exactly the half-asleep reflex this feature exists to defeat.
        .overlay {
            if container.alarmService.ringingAlarm != nil {
                AlarmRingingView()
                    .transition(.opacity)
            }
        }
        // The privacy overlay stays outermost, so the app-switcher snapshot
        // shows the lock screen rather than a ringing alarm naming the
        // contact you're about to message.
        .overlay {
            if container.appLockService.isObscured {
                PrivacyOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: container.appLockService.isObscured)
        .animation(.easeInOut(duration: 0.2), value: container.alarmService.ringingAlarm?.id)
        .task(id: isAppLockBlocking) {
            guard container.authService.isAuthenticated,
                  !container.authService.isStorageUnlocked,
                  !isAppLockBlocking else { return }
            await container.authService.unlockStorage()
        }
    }
}

/// Deliberately opaque rather than blurred: a blur of a chat transcript can
/// still leak message shape, sender colours and rough length.
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
