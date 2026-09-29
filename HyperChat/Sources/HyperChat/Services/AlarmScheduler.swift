import Foundation
import UserNotifications
import os

/// Schedules the local notifications that fire an alarm.
///
/// iOS gives third-party apps no true system-alarm API — only the Clock app
/// can override Focus modes and the mute switch. This rings through
/// notifications (with a follow-up burst so the sound repeats) and plays
/// looping audio via `AlarmAudioService` once the app is open.
@MainActor
final class AlarmScheduler {
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.HyperChat", category: "alarm")

    /// iOS keeps at most 64 pending local notifications per app and silently
    /// drops the rest. One repeating weekly trigger per weekday plus a
    /// 4-notification burst for the next occurrence costs 11 per alarm, so
    /// five alarms fit in 55.
    static let maxEnabledAlarms = 5
    private static let burstCount = 4
    private static let burstInterval: TimeInterval = 5

    static let categoryIdentifier = "HYPERCHAT_ALARM"
    private static let identifierPrefix = "alarm."

    func requestAuthorization() async -> Bool {
        do {
            // `.criticalAlert` is denied without Apple's entitlement; asking
            // costs nothing.
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
            // No "Dismiss" action: the alarm can't be silenced from the
            // notification shade without completing the challenge.
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    /// Replaces all scheduled notifications with ones matching `alarms`.
    /// Wholesale replacement is cheap and always correct.
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

    /// Follow-ups a few seconds apart, only for the next occurrence —
    /// a burst per weekday is what would blow the 64-notification budget.
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

    /// FIX (Pack 8): the backwards counterpart of `nextOccurrence`, used by
    /// `AlarmService.checkForDueAlarm` to find an occurrence that has just
    /// passed without being acknowledged.
    func mostRecentOccurrence(of alarm: Alarm, before date: Date) -> Date? {
        let calendar = Calendar.current

        if alarm.repeatsWeekly {
            return alarm.repeatWeekdays.compactMap { weekday -> Date? in
                var components = alarm.timeComponents
                components.weekday = weekday
                return calendar.nextDate(
                    after: date,
                    matching: components,
                    matchingPolicy: .nextTime,
                    direction: .backward
                )
            }.max()
        }
        return calendar.nextDate(
            after: date,
            matching: alarm.timeComponents,
            matchingPolicy: .nextTime,
            direction: .backward
        )
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
