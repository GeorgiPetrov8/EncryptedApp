import Foundation
import GRDB

/// Persists the shared notepad and implements its merge rule.
///
/// The merge rule — highest `updatedAt` wins, tie-broken by `updatedBy` —
/// was validated in isolation (commutativity under any delivery order,
/// idempotency under replay/duplicate application, deterministic tie-break,
/// and correct tombstone-vs-revive interaction) before being written here.
/// That matters specifically because notepad ops travel through the exact
/// same offline-queue / out-of-order / at-least-once delivery machinery
/// already built for chat messages (Bugs #8, #12) — two devices editing the
/// same item while one was offline is the *expected* case, not an edge case.
final class NotePadRepository {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    private static func key(ownerUserId: String, conversationId: String, itemId: String) -> [String: DatabaseValueConvertible] {
        ["ownerUserId": ownerUserId, "conversationId": conversationId, "itemId": itemId]
    }

    func fetchAll(ownerUserId: String, conversationId: String) throws -> [NotePadItem] {
        try dbQueue.read { db in
            try NotePadItem
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("conversationId") == conversationId)
                .order(Column("updatedAt").asc)
                .fetchAll(db)
        }
    }

    /// Applies the last-write-wins merge and persists the winner.
    ///
    /// - Returns: the resulting authoritative item, and whether the merge
    ///   actually changed anything. Callers use `changed` to skip a
    ///   redundant re-transmit when a local edit turns out to be a no-op
    ///   (e.g. re-applying an operation that already lost a race to a
    ///   newer one from the peer) — see `NotePadService.apply`.
    @discardableResult
    func upsertIfNewer(
        ownerUserId: String,
        conversationId: String,
        candidate: NotePadItem
    ) throws -> (item: NotePadItem, changed: Bool) {
        try dbQueue.write { db in
            guard let existing = try NotePadItem.fetchOne(
                db, key: Self.key(ownerUserId: ownerUserId, conversationId: conversationId, itemId: candidate.itemId)
            ) else {
                try candidate.insert(db)
                return (candidate, true)
            }

            let winner = Self.merge(existing, candidate)
            guard winner != existing else { return (existing, false) }
            try winner.update(db)
            return (winner, true)
        }
    }

    /// The merge rule itself, isolated as a pure function so it can be
    /// reasoned about (and was, ahead of writing this) independently of any
    /// database or network concern: highest `updatedAt` wins; an exact
    /// timestamp tie breaks on `updatedBy` so two devices converge on the
    /// same winner without coordinating.
    static func merge(_ a: NotePadItem, _ b: NotePadItem) -> NotePadItem {
        if b.updatedAt > a.updatedAt { return b }
        if b.updatedAt < a.updatedAt { return a }
        return b.updatedBy > a.updatedBy ? b : a
    }

    /// Used by account deletion, mirroring every other repository's
    /// `deleteAll(ownerUserId:)` — logout must not call this (Bug #10:
    /// logout never destroys data), only `AccountDeletionService` does.
    func deleteAll(ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try NotePadItem.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
        }
    }
}
