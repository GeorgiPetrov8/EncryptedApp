import SwiftUI
import UserNotifications
import os

/// FIX (Critical #4): tapping an alarm notification from a cold start now
/// actually starts the challenge.
///
/// ## The bug
///
/// `AppDelegate.container` was assigned in `SecureChatApp`'s `.task`, which
/// runs after the first view appears. On a cold start, iOS delivers
/// `didReceive response:` during launch — before that view exists. The handler
/// found `container == nil`, did nothing, and returned. The app opened to the
/// chat list with the alarm still scheduled but no challenge on screen, and
/// the audio never started.
///
/// So the exact scenario an alarm is *for* — phone locked, app not running,
/// notification wakes you — was the one case that silently did nothing.
///
/// ## The fix
///
/// Hold the alarm id until the container exists, then consume it. Also adds
/// the two guards the ticket correctly identified as missing: a stale
/// notification (tapped hours later, or from yesterday) and a disabled alarm
/// must not start ringing.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set from `SecureChatApp.task`. Until then, alarm taps are buffered.
    var container: AppContainer? {
        didSet {
            guard container != nil else { return }
            consumePendingAlarmIfNeeded()
        }
    }

    /// An alarm tap that arrived before the container existed.
    ///
    /// Carries the delivery date as well as the id, so staleness can be judged
    /// against when the notification actually fired rather than when the app
    /// finished launching — on a cold start those differ by seconds, but on a
    /// tap from the notification centre hours later they differ by hours.
    private var pendingAlarm: (id: String, firedAt: Date)?

    private let logger = Logger(subsystem: "com.HyperChat", category: "alarm")

    /// How late a notification tap can still start the alarm.
    ///
    /// Matches `AlarmService.autoExpiry`: an alarm the user never engaged with
    /// gives up after thirty minutes, so a tap after that window is
    /// archaeology, not a wake-up. Without this, opening notification centre
    /// and tapping yesterday's alarm would start a full challenge with audio.
    private static let staleAfter: TimeInterval = 30 * 60

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
        await handle(notification.request.content, firedAt: notification.date)
        return [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await handle(response.notification.request.content, firedAt: response.notification.date)
    }

    private func handle(_ content: UNNotificationContent, firedAt: Date) async {
        guard content.categoryIdentifier == AlarmScheduler.categoryIdentifier,
              let alarmId = content.userInfo["alarmId"] as? String else { return }

        await MainActor.run {
            guard let container else {
                // Cold start: the container doesn't exist yet. Buffer rather
                // than drop — this is the path that used to lose the tap.
                logger.debug("Alarm tap arrived before launch finished; buffering")
                pendingAlarm = (alarmId, firedAt)
                return
            }
            start(alarmId: alarmId, firedAt: firedAt, container: container)
        }
    }

    private func consumePendingAlarmIfNeeded() {
        guard let pending = pendingAlarm, let container else { return }
        pendingAlarm = nil
        start(alarmId: pending.id, firedAt: pending.firedAt, container: container)
    }

    @MainActor
    private func start(alarmId: String, firedAt: Date, container: AppContainer) {
        guard Date().timeIntervalSince(firedAt) < Self.staleAfter else {
            logger.info("Ignoring a stale alarm notification")
            return
        }
        container.alarmService.fireAlarm(id: alarmId, firedAt: firedAt)
    }
}

// MARK: - Required `AlarmService` changes
//
// 1. `fireAlarm` takes the fire date and validates it, instead of trusting
//    that any tap means "ring now":
//
//        func fireAlarm(id: String, firedAt: Date = Date()) {
//            guard ringingAlarm == nil,
//                  let ownerUserId = authService.currentUserId,
//                  let alarm = try? repository.fetch(ownerUserId: ownerUserId, id: id)
//            else { return }
//
//            // A disabled alarm must not ring. Without this, toggling an alarm
//            // off and then tapping its already-delivered notification starts
//            // a challenge for an alarm the user switched off.
//            guard alarm.isEnabled || alarm.repeatsWeekly else {
//                logger.info("Ignoring a notification for a disabled alarm")
//                return
//            }
//
//            // Already answered this occurrence.
//            if let dismissedAt = alarm.lastDismissedAt, dismissedAt >= firedAt {
//                logger.debug("Alarm occurrence already dismissed; ignoring")
//                return
//            }
//
//            beginRinging(alarm, markFired: true)
//        }
//
// 2. `activate()` gains the in-app check its documentation already claimed.
//    `resumeRingingIfNeeded` only resumed an alarm already marked as fired; if
//    the notification was never delivered or was cleared, opening the app at
//    the alarm time showed nothing at all. Add, at the end of `activate()`:
//
//        checkForDueAlarm(ownerUserId: ownerUserId)
//
//    ...and:
//
//        /// Starts an alarm whose scheduled time has just passed but which was
//        /// never acknowledged — the case where the notification was missed,
//        /// suppressed by a Focus mode, or swiped away.
//        private func checkForDueAlarm(ownerUserId: String) {
//            guard ringingAlarm == nil else { return }
//            let now = Date()
//            for alarm in alarms where alarm.isEnabled {
//                guard let due = scheduler.mostRecentOccurrence(of: alarm, before: now),
//                      now.timeIntervalSince(due) < Self.autoExpiry else { continue }
//                if let dismissedAt = alarm.lastDismissedAt, dismissedAt >= due { continue }
//                beginRinging(alarm, markFired: true)
//                return
//            }
//        }
//
// 3. `AlarmScheduler` needs the backwards counterpart of `nextOccurrence`:
//
//        func mostRecentOccurrence(of alarm: Alarm, before date: Date) -> Date? {
//            let calendar = Calendar.current
//            if alarm.repeatsWeekly {
//                return alarm.repeatWeekdays.compactMap { weekday -> Date? in
//                    var components = alarm.timeComponents
//                    components.weekday = weekday
//                    return calendar.nextDate(
//                        after: date, matching: components,
//                        matchingPolicy: .nextTime, direction: .backward
//                    )
//                }.max()
//            }
//            return calendar.nextDate(
//                after: date, matching: alarm.timeComponents,
//                matchingPolicy: .nextTime, direction: .backward
//            )
//        }
//
// 4. `pruneDeletedAccountabilityContacts` must distinguish a read failure from
//    an empty contact list (Medium #10). As written, `(try? fetchAll) ?? []`
//    turns a database error into "this account has no contacts", which then
//    downgrades *every* `.messageContact` alarm to tasks and discards the peer
//    ids permanently:
//
//        private func pruneDeletedAccountabilityContacts(ownerUserId: String) {
//            let contacts: [User]
//            do {
//                contacts = try userRepository.fetchAll(ownerUserId: ownerUserId)
//            } catch {
//                // Skip the sweep entirely rather than acting on a false empty.
//                logger.error("Couldn't read contacts; skipping accountability sweep")
//                return
//            }
//            try? repository.clearMissingAccountabilityPeers(
//                ownerUserId: ownerUserId,
//                existingPeerIds: Set(contacts.map(\.id))
//            )
//            reloadAlarms()
//        }
