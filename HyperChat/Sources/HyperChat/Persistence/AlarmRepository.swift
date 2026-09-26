import Foundation
import GRDB

final class AlarmRepository {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    private static func key(ownerUserId: String, id: String) -> [String: DatabaseValueConvertible] {
        ["ownerUserId": ownerUserId, "id": id]
    }

    func fetchAll(ownerUserId: String) throws -> [Alarm] {
        try dbQueue.read { db in
            try Alarm
                .filter(Column("ownerUserId") == ownerUserId)
                .order(Column("hour").asc, Column("minute").asc)
                .fetchAll(db)
        }
    }

    func fetchEnabled(ownerUserId: String) throws -> [Alarm] {
        try dbQueue.read { db in
            try Alarm
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("isEnabled") == true)
                .order(Column("hour").asc, Column("minute").asc)
                .fetchAll(db)
        }
    }

    func fetch(ownerUserId: String, id: String) throws -> Alarm? {
        try dbQueue.read { db in
            try Alarm.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: id))
        }
    }

    func save(_ alarm: Alarm) throws {
        try dbQueue.write { db in try alarm.save(db) }
    }

    func delete(ownerUserId: String, id: String) throws {
        _ = try dbQueue.write { db in
            try Alarm.deleteOne(db, key: Self.key(ownerUserId: ownerUserId, id: id))
        }
    }

    /// Records that an alarm started ringing.
    ///
    /// Written the moment the ringing UI appears rather than when the
    /// notification was scheduled, because the two can diverge: a scheduled
    /// notification the user never saw (phone off, notification suppressed)
    /// must not leave a stale "currently ringing" state that resumes hours
    /// later on next launch.
    func markFired(ownerUserId: String, id: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            guard var alarm = try Alarm.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: id)) else { return }
            alarm.lastFiredAt = date
            try alarm.update(db)
        }
    }

    /// Records a successful dismissal, and auto-disables one-shot alarms.
    ///
    /// A non-repeating alarm that stayed enabled after firing would ring
    /// again at the same time tomorrow, which is not what "Once" means.
    func markDismissed(ownerUserId: String, id: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            guard var alarm = try Alarm.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: id)) else { return }
            alarm.lastDismissedAt = date
            if !alarm.repeatsWeekly {
                alarm.isEnabled = false
            }
            try alarm.update(db)
        }
    }

    /// Any alarm for this account that fired recently and was never
    /// silenced — used at launch to resume ringing after a force-quit.
    func fetchUnresolvedRinging(ownerUserId: String, window: TimeInterval, now: Date = Date()) throws -> Alarm? {
        try dbQueue.read { db in
            try Alarm
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("lastFiredAt") != nil)
                .order(Column("lastFiredAt").desc)
                .fetchAll(db)
                .first { $0.isCurrentlyRinging(now: now, window: window) }
        }
    }

    /// Clears the `accountabilityPeerId` of any alarm pointing at a contact
    /// that no longer exists, so the alarm degrades to a plain task
    /// challenge instead of being unsilenceable.
    ///
    /// See `Alarm.accountabilityPeerId` for why this is done explicitly
    /// rather than by a cascading foreign key.
    func clearMissingAccountabilityPeers(ownerUserId: String, existingPeerIds: Set<String>) throws {
        try dbQueue.write { db in
            let alarms = try Alarm
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("accountabilityPeerId") != nil)
                .fetchAll(db)
            for var alarm in alarms {
                guard let peerId = alarm.accountabilityPeerId, !existingPeerIds.contains(peerId) else { continue }
                alarm.accountabilityPeerId = nil
                alarm.dismissalMode = .tasks
                try alarm.update(db)
            }
        }
    }

    func deleteAll(ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try Alarm.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
        }
    }
}
