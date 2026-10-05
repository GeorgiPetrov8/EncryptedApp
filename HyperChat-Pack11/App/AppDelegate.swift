import SwiftUI
import UserNotifications
import os

/// Notification delivery and taps, plus APNs device-token registration.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    var container: AppContainer? {
        didSet {
            guard let container else { return }
            consumePendingAlarmIfNeeded()
            if let token = pendingDeviceToken {
                pendingDeviceToken = nil
                container.pushService.didRegister(deviceToken: token)
            }
        }
    }

    private var pendingAlarm: (id: String, firedAt: Date)?
    /// APNs can hand over the token before the container exists.
    private var pendingDeviceToken: Data?

    private let logger = Logger(subsystem: "com.HyperChat", category: "app")
    private static let staleAfter: TimeInterval = AlarmService.autoExpiry

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: Push registration

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        if let container {
            container.pushService.didRegister(deviceToken: deviceToken)
        } else {
            pendingDeviceToken = deviceToken
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Typical causes: running in the Simulator without a paired device,
        // or the Push Notifications capability missing from the target.
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: Notifications

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        handle(notification.request.content, firedAt: notification.date)
        return [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        handle(response.notification.request.content, firedAt: response.notification.date)
    }

    private func handle(_ content: UNNotificationContent, firedAt: Date) {
        guard content.categoryIdentifier == AlarmScheduler.categoryIdentifier,
              let alarmId = content.userInfo["alarmId"] as? String else { return }

        guard let container else {
            pendingAlarm = (alarmId, firedAt)
            return
        }
        start(alarmId: alarmId, firedAt: firedAt, container: container)
    }

    private func consumePendingAlarmIfNeeded() {
        guard let pending = pendingAlarm, let container else { return }
        pendingAlarm = nil
        start(alarmId: pending.id, firedAt: pending.firedAt, container: container)
    }

    private func start(alarmId: String, firedAt: Date, container: AppContainer) {
        guard Date().timeIntervalSince(firedAt) < Self.staleAfter else {
            logger.info("Ignoring a stale alarm notification")
            return
        }
        container.alarmService.fireAlarm(id: alarmId, firedAt: firedAt)
    }
}
