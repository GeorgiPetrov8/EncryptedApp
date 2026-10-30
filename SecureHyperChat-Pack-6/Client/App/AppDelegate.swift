import SwiftUI
import UserNotifications
import os

/// Notification delivery and taps (alarms, invitations).
///
/// Apple push registration is gone: no paid developer account, ntfy only.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var container: AppContainer? {
        didSet { consumePendingAlarmIfNeeded() }
    }

    private var pendingAlarm: (id: String, firedAt: Date)?
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "app")
    private static let staleAfter: TimeInterval = AlarmService.autoExpiry

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
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
