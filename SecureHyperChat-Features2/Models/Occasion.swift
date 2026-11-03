import Foundation
import GRDB

/// #15: a date both people in a chat share (a birthday, an anniversary…).
/// On that day the chat shows confetti and a banner, on both phones.
///
/// Set by either person and synced as a control message (`.occasion`), so both
/// phones agree on the same date. The newest change wins (by `setAt`, tie on
/// `setBy`); removing it is a change too, so a stale "set" can't bring it back.
struct Occasion: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case birthday, anniversary, other
        var id: String { rawValue }

        var title: String {
            switch self {
            case .birthday: return "Birthday"
            case .anniversary: return "Anniversary"
            case .other: return "Special day"
            }
        }

        var emoji: String {
            switch self {
            case .birthday: return "🎂"
            case .anniversary: return "💞"
            case .other: return "✨"
            }
        }
    }

    var kind: Kind
    var label: String?
    var month: Int
    var day: Int
    /// Optional: lets the banner say "3 years".
    var year: Int?
    var setAt: Date
    var setBy: String
    var removed: Bool

    static let maxLabelLength = 40

    /// Rejects impossible dates and cleans the label (data from the other phone).
    func validated() -> Occasion? {
        guard (1...12).contains(month), day >= 1 else { return nil }
        let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard day <= daysInMonth else { return nil }
        let thisYear = Calendar.current.component(.year, from: Date())
        let cleanYear = year.flatMap { (1900...thisYear).contains($0) ? $0 : nil }
        var copy = self
        copy.label = SafeText.line(label, maxLength: Self.maxLabelLength)
        copy.year = cleanYear
        copy.setAt = min(setAt, Date().addingTimeInterval(5 * 60))
        guard !setBy.isEmpty, setBy.count <= 64 else { return nil }
        return copy
    }

    /// Is `date` the occasion, in the phone's own calendar? 29 Feb is celebrated
    /// on 28 Feb in non-leap years.
    func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard !removed else { return false }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let m = c.month, let d = c.day, let y = c.year else { return false }
        if month == 2 && day == 29 && !Self.isLeap(y) {
            return m == 2 && d == 28
        }
        return m == month && d == day
    }

    /// Years since `year`, if known and positive.
    func years(on date: Date, calendar: Calendar = .current) -> Int? {
        guard let year else { return nil }
        let n = calendar.component(.year, from: date) - year
        return n > 0 ? n : nil
    }

    /// Newest change wins; ties broken by user id, so both phones agree.
    func isNewer(than other: Occasion) -> Bool {
        if setAt != other.setAt { return setAt > other.setAt }
        return setBy > other.setBy
    }

    private static func isLeap(_ y: Int) -> Bool {
        (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    }
}

/// Table `occasions`, one row per account and chat.
struct OccasionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "occasions"

    var ownerUserId: String
    var conversationId: String
    var occasion: Occasion   // stored as JSON
}
