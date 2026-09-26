import Foundation
import UserNotifications
import os

/// Schedules the local notifications that fire an alarm.
///
/// ## What iOS actually allows here
///
/// This is worth being blunt about, because an alarm that quietly doesn't
/// go off is worse than no alarm. iOS gives third-party apps **no** true
/// system-alarm API. The built-in Clock app can wake the device, override
/// the mute switch and ignore Do Not Disturb; an App Store app cannot,
/// unless Apple grants the Critical Alerts entitlement (a manual approval
/// normally reserved for medical and safety apps).
///
/// What this implementation does within those limits:
///   - schedules `UNCalendarNotificationTrigger`s with a sound, which ring
///     at the right time and show on the lock screen;
///   - fires a short burst of follow-up notifications so the sound repeats
///     rather than playing once and stopping;
///   - plays looping audio via `AlarmAudioService` once the app is actually
///     open, which *can* override the silent switch and keeps going until
///     the challenge is solved.
///
/// What it cannot do: guarantee sound if the phone is in Do Not Disturb or
/// a Focus mode that filters this app, or start audio on its own while
/// terminated. Those limits are documented in the alarm setup screen too,
/// rather than left for the user to discover by oversleeping.
@MainActor
final class AlarmScheduler {
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.HyperChat", category: "alarm")

    /// iOS keeps at most 64 pending local notifications per app and
    /// silently drops the rest — so the scheduling strategy has to fit
    /// inside that budget by design, not by luck.
    ///
    /// Strategy: one *repeating* weekly trigger per selected weekday (those
    /// never need rescheduling), plus a small burst of one-shots for the
    /// single next occurrence, refreshed whenever the app foregrounds.
    /// That costs `weekdays + burst` per alarm instead of
    /// `weekdays × burst`, which is the difference between 11 and 28
    /// notifications for one daily alarm.
    ///
    /// At 7 weekdays + 4 burst = 11 per alarm, five alarms fit in 55. The
    /// UI enforces that cap rather than letting the overflow disappear.
    static let maxEnabledAlarms = 5
    private static let burstCount = 4
    private static let burstInterval: TimeInterval = 5

    static let categoryIdentifier = "HyperChat_ALARM"
    private static let identifierPrefix = "alarm."

    func requestAuthorization() async -> Bool {
        do {
            // `.criticalAlert` is requested but will simply be denied
            // without the Apple entitlement — asking costs nothing and
            // means the app behaves correctly for anyone who does have it.
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert])
            registerCategory()
            return granted
        } catch {
            logger.error("Notification authorization failed")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    private func registerCategory() {
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            // No "Dismiss" action deliberately: the whole point is that the
            // alarm can't be silenced from the notification shade without
            // opening the app and completing the challenge.
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    /// Replaces all scheduled notifications with ones matching `alarms`.
    ///
    /// Wholesale replacement rather than incremental add/remove: reconciling
    /// individual notification identifiers against edited alarms is fiddly
    /// and gets out of sync in exactly the cases that matter (an alarm
    /// edited while one of its own notifications is pending). Rescheduling
    /// everything is cheap and always correct.
    func reschedule(alarms: [Alarm]) async {
        center.removeAllPendingNotificationRequests()
        registerCategory()

        let enabled = alarms.filter(\.isEnabled).prefix(Self.maxEnabledAlarms)

        for alarm in enabled {
            if alarm.repeatsWeekly {
                for weekday in alarm.repeatWeekdays {
                    await add(alarm: alarm, weekday: weekday, suffix: "w\(weekday)", repeats: true)
                }
            } else {
                await add(alarm: alarm, weekday: nil, suffix: "once", repeats: false)
            }
            await addBurst(for: alarm)
        }

        let pending = await center.pendingNotificationRequests().count
        logger.info("Scheduled \(pending, privacy: .public) alarm notifications for \(enabled.count, privacy: .public) alarm(s)")
    }

    private func add(alarm: Alarm, weekday: Int?, suffix: String, repeats: Bool) async {
        var components = alarm.timeComponents
        if let weekday { components.weekday = weekday }

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        let request = UNNotificationRequest(
            identifier: "\(Self.identifierPrefix)\(alarm.id).\(suffix)",
            content: content(for: alarm),
            trigger: trigger
        )
        do {
            try await center.add(request)
        } catch {
            logger.error("Couldn't schedule alarm notification")
        }
    }

    /// Follow-up notifications a few seconds apart, so a missed first sound
    /// isn't the end of it. Only ever scheduled for the next occurrence —
    /// scheduling a burst per weekday is what blows the 64-notification
    /// budget.
    private func addBurst(for alarm: Alarm) async {
        guard let next = nextOccurrence(of: alarm) else { return }

        for index in 1...Self.burstCount {
            let fireDate = next.addingTimeInterval(Double(index) * Self.burstInterval)
            guard fireDate > Date() else { continue }

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate
            )
            let request = UNNotificationRequest(
                identifier: "\(Self.identifierPrefix)\(alarm.id).burst\(index)",
                content: content(for: alarm),
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private func content(for alarm: Alarm) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alarm.label.isEmpty ? "Alarm" : alarm.label
        content.body = alarm.dismissalMode == .tasks
            ? "Open to solve \(alarm.requiredTaskCount) problems and stop the alarm."
            : "Open to send your word and stop the alarm."
        content.sound = .defaultCritical
        content.categoryIdentifier = Self.categoryIdentifier
        content.interruptionLevel = .timeSensitive
        // Carried through so the app knows which alarm a tapped
        // notification belongs to — without it, two alarms at nearby times
        // are indistinguishable on open.
        content.userInfo = ["alarmId": alarm.id]
        return content
    }

    func nextOccurrence(of alarm: Alarm) -> Date? {
        let calendar = Calendar.current
        let now = Date()

        if alarm.repeatsWeekly {
            return alarm.repeatWeekdays.compactMap { weekday -> Date? in
                var components = alarm.timeComponents
                components.weekday = weekday
                return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
            }.min()
        }
        return calendar.nextDate(after: now, matching: alarm.timeComponents, matchingPolicy: .nextTime)
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
