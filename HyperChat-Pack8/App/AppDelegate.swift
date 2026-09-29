import SwiftUI
import UserNotifications
import os

/// Handles notification delivery and taps.
///
/// FIX (Pack 8, Critical #4): tapping an alarm notification from a cold start
/// now actually starts the challenge.
///
/// `container` is assigned in the App's `.task`, which runs after the first
/// view appears. On a cold start iOS delivers `didReceive response:` during
/// launch — before that view exists — so the tap used to find
/// `container == nil` and was dropped. The alarm was scheduled, the app opened,
/// and nothing rang: the exact scenario an alarm exists for was the one that
/// silently failed.
///
/// The tap is now buffered until the container exists, then consumed.
///
/// `@MainActor` on the whole class (rather than `MainActor.run` blocks) so the
/// `container` `didSet` can call main-actor code directly. The async
/// `UNUserNotificationCenterDelegate` methods still satisfy their nonisolated
/// protocol requirements, because an actor-isolated async method is a valid
/// witness for a nonisolated async requirement.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set from the App's `.task`. Until then, alarm taps are buffered.
    var container: AppContainer? {
        didSet {
            guard container != nil else { return }
            consumePendingAlarmIfNeeded()
        }
    }

    /// An alarm tap that arrived before the container existed. Carries the
    /// delivery date so staleness is judged against when the notification
    /// actually fired, not when the app finished launching.
    private var pendingAlarm: (id: String, firedAt: Date)?

    private let logger = Logger(subsystem: "com.HyperChat", category: "alarm")

    /// Matches `AlarmService.autoExpiry`: a tap after this window is
    /// archaeology, not a wake-up. Without it, tapping yesterday's alarm in
    /// Notification Centre would start a full challenge with audio.
    private static let staleAfter: TimeInterval = AlarmService.autoExpiry

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Without this, a notification arriving while the app is open is
    /// suppressed entirely.
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
            // Cold start: buffer rather than drop — this is the path that used
            // to lose the tap.
            logger.debug("Alarm tap arrived before launch finished; buffering")
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
