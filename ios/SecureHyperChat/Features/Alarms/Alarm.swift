import Foundation
import GRDB

/// How an alarm can be silenced.
///
/// Both modes exist to defeat the same failure: hitting dismiss while
/// asleep and going straight back to bed with no memory of it. Tasks make
/// you think; the accountability mode makes someone else aware you're up.
enum AlarmDismissalMode: String, Codable, CaseIterable, Equatable {
    /// Solve N mental arithmetic tasks (default 3).
    case tasks
    /// Send a generated word to a chosen contact, over the normal
    /// end-to-end encrypted channel. Falls back to `tasks` if the message
    /// genuinely cannot be sent — see `AlarmService` for why.
    case messageContact

    var title: String {
        switch self {
        case .tasks: return "Solve 3 problems"
        case .messageContact: return "Message someone a word"
        }
    }

    var explanation: String {
        switch self {
        case .tasks:
            return "The alarm keeps ringing until you answer three arithmetic problems correctly."
        case .messageContact:
            return "The alarm keeps ringing until you send a randomly generated word to the contact you pick. They'll know you're up."
        }
    }
}

/// One configured alarm, owned by one local account.
///
/// Composite-keyed by `(ownerUserId, id)` from the start, consistent with
/// every other table here after the account-isolation corrections — two
/// accounts on one device must not see or silence each other's alarms.
struct Alarm: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "alarms"

    var ownerUserId: String
    var id: String
    var hour: Int
    var minute: Int
    var isEnabled: Bool
    var label: String

    /// `Calendar.component(.weekday)` values: 1 = Sunday … 7 = Saturday.
    ///
    /// Stored in exactly that convention rather than a 0-indexed or
    /// Monday-first one, because `UNCalendarNotificationTrigger` consumes
    /// `DateComponents.weekday`, which uses the same numbering. Translating
    /// between conventions is a classic source of off-by-one scheduling
    /// bugs that only show up on one day of the week.
    ///
    /// Empty means "fire once at the next occurrence, then disable".
    var repeatWeekdays: [Int]

    var dismissalMode: AlarmDismissalMode
    /// The contact to message, for `.messageContact` mode.
    ///
    /// Deliberately **not** a foreign key to `users`. A cascade delete would
    /// silently remove the alarm if that contact were ever deleted, which
    /// is the wrong failure: an alarm vanishing without warning is worse
    /// than one that survives and reports "the contact this alarm points at
    /// is gone, pick another" — which is what `AlarmService` does.
    var accountabilityPeerId: String?
    var requiredTaskCount: Int

    /// When this alarm last started ringing, and when it was last silenced.
    ///
    /// The pair exists so a ringing alarm survives the app being force-quit:
    /// if `lastFiredAt > lastDismissedAt` and the fire was recent, the alarm
    /// resumes on next launch instead of being quietly killed by swiping the
    /// app away — which would otherwise be the single easiest bypass of the
    /// whole feature.
    var lastFiredAt: Date?
    var lastDismissedAt: Date?

    var createdAt: Date

    init(
        ownerUserId: String,
        id: String = UUID().uuidString,
        hour: Int,
        minute: Int,
        isEnabled: Bool = true,
        label: String = "Alarm",
        repeatWeekdays: [Int] = [],
        dismissalMode: AlarmDismissalMode = .tasks,
        accountabilityPeerId: String? = nil,
        requiredTaskCount: Int = 3,
        lastFiredAt: Date? = nil,
        lastDismissedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.ownerUserId = ownerUserId
        self.id = id
        self.hour = hour
        self.minute = minute
        self.isEnabled = isEnabled
        self.label = label
        self.repeatWeekdays = repeatWeekdays
        self.dismissalMode = dismissalMode
        self.accountabilityPeerId = accountabilityPeerId
        self.requiredTaskCount = requiredTaskCount
        self.lastFiredAt = lastFiredAt
        self.lastDismissedAt = lastDismissedAt
        self.createdAt = createdAt
    }

    var timeComponents: DateComponents {
        DateComponents(hour: hour, minute: minute)
    }

    var formattedTime: String {
        String(format: "%02d:%02d", hour, minute)
    }

    var repeatsWeekly: Bool { !repeatWeekdays.isEmpty }

    /// True when this alarm started ringing and hasn't been silenced yet.
    func isCurrentlyRinging(now: Date = Date(), window: TimeInterval) -> Bool {
        guard let lastFiredAt else { return false }
        if let lastDismissedAt, lastDismissedAt >= lastFiredAt { return false }
        return now.timeIntervalSince(lastFiredAt) < window
    }

    var repeatSummary: String {
        guard repeatsWeekly else { return "Once" }
        if Set(repeatWeekdays) == Set(1...7) { return "Every day" }
        if Set(repeatWeekdays) == Set([2, 3, 4, 5, 6]) { return "Weekdays" }
        if Set(repeatWeekdays) == Set([1, 7]) { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return repeatWeekdays.sorted()
            .compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
            .joined(separator: " ")
    }
}
