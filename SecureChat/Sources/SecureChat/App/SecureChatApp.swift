import SwiftUI

@main
struct SecureChatApp: App {
    @StateObject private var container = AppContainer.bootstrap()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background:
                        container.appLockService.appDidEnterBackground()
                    case .active:
                        container.appLockService.appWillEnterForeground()
                    default:
                        break
                    }
                }
        }
    }
}
