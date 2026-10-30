import Foundation
import UserNotifications
import os

/// Schedules the local notifications that fire an alarm.
///
/// iOS gives third-party apps no true system-alarm API — only the Clock app
/// can override Focus modes and the mute switch. This rings through
/// notifications (with a follow-up burst so the sound repeats) and plays
/// looping audio via `AlarmAudioService` once the app is open.
///
/// FIX (S37): only this scheduler's own notifications are ever removed.
/// `reschedule` and `cancelAll` used `removeAll…`, which also wiped invitation
/// notifications and anything else the app had pending or delivered.
///
/// FIX (F10): the notification plays the bundled `alarm.wav` (≤ 30 s), not the
/// default tri-tone. Without a paid developer account `.timeSensitive` and
/// critical alerts aren't granted; iOS then simply delivers a normal alert.
@MainActor
final class AlarmScheduler {
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "alarm")

    static let maxEnabledAlarms = 5
    private static let burstCount = 4
    private static let burstInterval: TimeInterval = 5

    static let categoryIdentifier = "HYPERCHAT_ALARM"
    private static let identifierPrefix = "alarm."
    private static let soundFile = "alarm.wav"

    func requestAuthorization() async -> Bool {
        do {
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
        let alarm = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        // Keep categories registered by other parts of the app (invitations).
        center.getNotificationCategories { [center] existing in
            var all = existing.filter { $0.identifier != Self.categoryIdentifier }
            all.insert(alarm)
            center.setNotificationCategories(all)
        }
    }

    /// Ids of this scheduler's pending requests.
    private func ownPendingIds() async -> [String] {
        await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
    }

    private func ownDeliveredIds() async -> [String] {
        await center.deliveredNotifications()
            .map(\.request.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
    }

    /// Replaces all scheduled alarm notifications with ones matching `alarms`.
    func reschedule(alarms: [Alarm]) async {
        center.removePendingNotificationRequests(withIdentifiers: await ownPendingIds())
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

        let pending = await ownPendingIds().count
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
        if Bundle.main.url(forResource: "alarm", withExtension: "wav") != nil {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(Self.soundFile))
        } else {
            content.sound = .defaultCritical
        }
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

    func mostRecentOccurrence(of alarm: Alarm, before date: Date) -> Date? {
        let calendar = Calendar.current
        if alarm.repeatsWeekly {
            return alarm.repeatWeekdays.compactMap { weekday -> Date? in
                var components = alarm.timeComponents
                components.weekday = weekday
                return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime, direction: .backward)
            }.max()
        }
        return calendar.nextDate(after: date, matching: alarm.timeComponents, matchingPolicy: .nextTime, direction: .backward)
    }

    /// Logout: removes only alarm notifications (S37).
    func cancelAll() {
        Task {
            let pending = await ownPendingIds()
            let delivered = await ownDeliveredIds()
            center.removePendingNotificationRequests(withIdentifiers: pending)
            center.removeDeliveredNotifications(withIdentifiers: delivered)
        }
    }

    /// Clears delivered alarm banners once the alarm has been dismissed.
    func clearDelivered() {
        Task {
            center.removeDeliveredNotifications(withIdentifiers: await ownDeliveredIds())
        }
    }
}
