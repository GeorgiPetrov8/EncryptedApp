import SwiftUI

@main
struct HyperChatApp: App {
    @StateObject private var container = AppContainer.bootstrap()
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
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
                        // FIX (online status): stop appearing online right away,
                        // rather than whenever iOS gets round to killing the socket.
                        container.presenceService.setAppActive(false)
                    case .active:
                        container.appLockService.appWillEnterForeground()
                        container.presenceService.setAppActive(true)
                        Task { await container.alarmService.activate() }
                    @unknown default:
                        break
                    }
                }
        }
    }
}
