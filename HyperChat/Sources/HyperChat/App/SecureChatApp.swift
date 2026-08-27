import SwiftUI

@main
struct HyperChatApp: App {
    @StateObject private var container = AppContainer.bootstrap()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                // FIX (Bug #26): two-parameter `onChange`, required from iOS 17.
                // FIX (Bug #24): `.inactive` is now handled.
                //
                // iOS takes the app-switcher snapshot during the `.inactive`
                // transition, before `.background`. Reacting only to `.background`
                // meant the screenshot of the open conversation had already been
                // captured by the time anything ran.
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .inactive:
                        container.appLockService.appWillResignActive()
                    case .background:
                        container.appLockService.appDidEnterBackground()
                    case .active:
                        container.appLockService.appWillEnterForeground()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
