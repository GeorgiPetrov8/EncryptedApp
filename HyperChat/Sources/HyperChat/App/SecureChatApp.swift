import SwiftUI
import UserNotifications

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
                    // FIX (alarm): the delegate is what turns a tapped alarm
                    // notification into a ringing challenge, and what makes
                    // the notification show at all while the app is already
                    // open. It needs a reference to the live container,
                    // which only exists here.
                    appDelegate.container = container
                    await container.alarmService.activate()
                }
                // Two-parameter `onChange`, required from iOS 17.
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .inactive:
                        // iOS takes the app-switcher snapshot during the
                        // `.inactive` transition, before `.background` — so
                        // reacting only to `.background` would mean the
                        // screenshot is already taken by the time anything
                        // runs.
                        container.appLockService.appWillResignActive()
                    case .background:
                        container.appLockService.appDidEnterBackground()
                    case .active:
                        container.appLockService.appWillEnterForeground()
                        // Refreshes the burst notifications for the next
                        // occurrence and re-checks whether an alarm fired
                        // while the app was closed — see `AlarmScheduler`
                        // for why the burst is only ever scheduled for the
                        // nearest occurrence.
                        Task { await container.alarmService.activate() }
                    @unknown default:
                        break
                    }
                }
        }
    }
}

/// Handles notification delivery and taps.
///
/// SwiftUI has no first-class hook for either, so a `UIApplicationDelegate`
/// remains the supported route — `@UIApplicationDelegateAdaptor` is the
/// intended bridge rather than a workaround.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Assigned from `HyperChatApp.task`; the delegate is constructed by
    /// SwiftUI before the container exists, so this can't be injected.
    var container: AppContainer?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Without this, a notification arriving while the app is open is
    /// suppressed entirely — which would mean an alarm that silently does
    /// nothing whenever you happen to be holding the phone.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await handle(notification.request.content)
        return [.banner, .sound, .list]
    }

    /// Tapping the notification opens the app straight into the challenge.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await handle(response.notification.request.content)
    }

    private func handle(_ content: UNNotificationContent) async {
        guard content.categoryIdentifier == AlarmScheduler.categoryIdentifier,
              let alarmId = content.userInfo["alarmId"] as? String else { return }
        await MainActor.run {
            container?.alarmService.fireAlarm(id: alarmId)
        }
    }
}
