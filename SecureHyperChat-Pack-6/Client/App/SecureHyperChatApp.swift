import SwiftUI

@main
struct SecureHyperChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var bootstrap = AppContainer.tryBootstrap()

    var body: some Scene {
        WindowGroup {
            switch bootstrap {
            case .success(let container):
                ReadyApp(container: container, appDelegate: appDelegate)
            case .failure(let error):
                DatabaseFailureView(error: error) {
                    bootstrap = AppContainer.tryBootstrap()
                }
            }
        }
    }
}

private struct ReadyApp: View {
    @StateObject private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    let appDelegate: AppDelegate

    init(container: AppContainer, appDelegate: AppDelegate) {
        _container = StateObject(wrappedValue: container)
        self.appDelegate = appDelegate
    }

    var body: some View {
        RootView()
            .environmentObject(container)
            .task {
                appDelegate.container = container
                await container.alarmService.activate()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .inactive:
                    container.appLockService.appWillResignActive()
                case .background:
                    container.appLockService.appDidEnterBackground()
                    container.presenceService.setAppActive(false)
                    container.connectionMonitor.appWentToBackground()
                case .active:
                    container.appLockService.appWillEnterForeground()
                    container.presenceService.setAppActive(true)
                    container.sessionRenewal.appBecameActive()
                    // #2: reconnect and catch up without visiting Settings.
                    container.connectionMonitor.appBecameActive()
                    Task { await container.alarmService.activate() }
                @unknown default:
                    break
                }
            }
    }
}
