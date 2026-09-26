import Foundation
import GRDB

/// One line on the shared note/todo/buy pad, as seen by **one** local
/// account for **one** conversation.
///
/// Scoped by `(ownerUserId, conversationId, itemId)` — the same lesson
/// learned repeatedly across this project's account-isolation bugs (#10,
/// #13, and the media pack's `MediaRepository` fixes): every table must be
/// keyed per local account, or two accounts signed in on the same device
/// corrupt each other's data. Here specifically, without `ownerUserId`, two
/// local accounts sharing a device could merge their *separate* pads with
/// two different peers into one, since `conversationId` alone is not
/// guaranteed unique across accounts (see `Conversation.deterministicId`).
struct NotePadItem: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "note_pad_items"

    var ownerUserId: String
    var conversationId: String
    var itemId: String
    var text: String
    var isDone: Bool

    /// A tombstone, not a hard delete.
    ///
    /// Hard-deleting the row the moment a user swipes to delete would break
    /// convergence: if the peer's device was offline and has an in-flight
    /// edit to that same item (e.g. they'd just checked it off right before
    /// losing connectivity), that edit arriving *after* a hard delete would
    /// have nothing to merge against and would silently resurrect the row
    /// with no memory of it ever being deleted — or, depending on insert
    /// vs. update semantics, get dropped entirely. A tombstone participates
    /// in the exact same last-write-wins merge as every other field, so
    /// "deleted at T=5" cleanly loses to "text edited at T=6" and cleanly
    /// beats "checked off at T=4", regardless of which order the two
    /// devices happen to observe those edits in.
    var isDeleted: Bool

    var updatedAt: Date
    /// The userId (not device id — this app has no separate device
    /// identity) of whoever made the most recent edit. Used only as the
    /// deterministic tie-breaker when two edits share the exact same
    /// `updatedAt` — see `NotePadRepository.merge`.
    var updatedBy: String

    /// `Identifiable` conformance for SwiftUI `ForEach`. Computed, not
    /// stored, so it plays no part in `Codable`/GRDB column mapping —
    /// `itemId` remains the one column identity actually lives in.
    var id: String { itemId }
}
