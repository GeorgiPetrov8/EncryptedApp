import Foundation
import GRDB

/// #5: how many days in a row a 1:1 chat had at least one message (either side).
///
/// Computed on each phone from its own messages, in the phone's own time zone.
/// Nothing is sent over the wire: two phones in different zones each decide
/// what "today" is, so there's no counter to disagree about.
///
/// A streak survives until the end of today: if you haven't written yet today
/// but did yesterday, it still counts.
///
/// Query: messages are grouped by UTC hour and only the first and last of each
/// hour are read (at most 24 rows a day, 400 days back). Every local day that
/// has a message is the local day of some hour's first or last message — this
/// holds for any UTC offset, including +5:30 and +5:45 (checked).
@MainActor
final class StreakService {
    /// Badge is shown from this many days.
    static let minimumShown = 2
    private static let lookbackDays = 400
    private static let cacheLifetime: TimeInterval = 60

    private let dbQueue: DatabaseQueue
    private var cache: [String: (value: Int, at: Date, dayKey: String)] = [:]

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// 0 for groups, chats that aren't accepted, and errors.
    func streak(for conversation: Conversation, now: Date = Date()) -> Int {
        guard !conversation.isGroup, conversation.relationshipState == .accepted else { return 0 }
        let todayKey = Self.dayKey(now, Calendar.current)
        let key = "\(conversation.ownerUserId)|\(conversation.id)"
        if let cached = cache[key], cached.dayKey == todayKey, now.timeIntervalSince(cached.at) < Self.cacheLifetime {
            return cached.value
        }
        let value = compute(ownerUserId: conversation.ownerUserId, conversationId: conversation.id, now: now)
        cache[key] = (value, now, todayKey)
        return value
    }

    /// Call when a message is sent or received in this chat.
    func invalidate(conversationId: String) {
        cache = cache.filter { !$0.key.hasSuffix("|\(conversationId)") }
    }

    func invalidateAll() {
        cache.removeAll()
    }

    private func compute(ownerUserId: String, conversationId: String, now: Date) -> Int {
        let calendar = Calendar.current
        let cutoff = now.addingTimeInterval(-Double(Self.lookbackDays) * 86_400)
        let rows: [Row]
        do {
            rows = try dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT MIN(createdAt) AS first, MAX(createdAt) AS last
                    FROM messages
                    WHERE ownerUserId = ? AND conversationId = ? AND createdAt >= ?
                    GROUP BY strftime('%Y-%m-%d %H', createdAt)
                    """, arguments: [ownerUserId, conversationId, cutoff])
            }
        } catch {
            return 0
        }
        var days = Set<String>()
        for row in rows {
            if let first: Date = row["first"] { days.insert(Self.dayKey(first, calendar)) }
            if let last: Date = row["last"] { days.insert(Self.dayKey(last, calendar)) }
        }
        return Self.count(days: days, now: now, calendar: calendar)
    }

    /// Pure: consecutive days ending today, or yesterday if today has none yet.
    nonisolated static func count(days: Set<String>, now: Date, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        // Noon, so stepping back by a day never lands on a skipped midnight (DST).
        guard var cursor = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) else { return 0 }
        if !days.contains(dayKey(cursor, calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(dayKey(yesterday, calendar)) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while days.contains(dayKey(cursor, calendar)), count <= lookbackDays {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    nonisolated static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
