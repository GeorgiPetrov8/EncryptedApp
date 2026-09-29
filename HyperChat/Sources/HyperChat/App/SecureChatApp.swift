import SwiftUI

/// FIX (Pack 8): `AppDelegate` moved to its own file (`AppDelegate.swift`).
///
/// If your App struct has a different name, keep your name — the only change
/// in this file is that the `AppDelegate` class that used to live at the
/// bottom is **gone**. Leaving it here as well would be a duplicate
/// declaration.
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
                    // Assigning this also consumes any alarm tap that arrived
                    // during a cold start (see `AppDelegate.container`).
                    appDelegate.container = container
                    await container.alarmService.activate()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .inactive:
                        // iOS takes the app-switcher snapshot during the
                        // `.inactive` transition, before `.background`.
                        container.appLockService.appWillResignActive()
                    case .background:
                        container.appLockService.appDidEnterBackground()
                    case .active:
                        container.appLockService.appWillEnterForeground()
                        Task { await container.alarmService.activate() }
                    @unknown default:
                        break
                    }
                }
        }
    }
}
