import Foundation

/// FIX (Bug #12): remembers how far each account has drained its server-side queue.
///
/// Stored per user id, because two accounts on the same device have independent
/// queues — a single shared cursor would let one account's sync skip the other's
/// pending messages.
///
/// `UserDefaults` is appropriate here: the cursor is a small integer with no
/// confidentiality requirement (it reveals nothing beyond "this account has synced
/// up to N"), and losing it is harmless — a reset cursor simply re-downloads
/// envelopes, which the replay protection from Bug #8 then deduplicates.
struct SyncCursorStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for userId: String) -> String {
        "sync.cursor.\(userId)"
    }

    func cursor(for userId: String) -> Int {
        defaults.integer(forKey: key(for: userId))
    }

    /// Only ever moves forward, so an out-of-order or retried sync can't rewind
    /// progress and re-deliver everything.
    func advance(to cursor: Int, for userId: String) {
        guard cursor > self.cursor(for: userId) else { return }
        defaults.set(cursor, forKey: key(for: userId))
    }

    func reset(for userId: String) {
        defaults.removeObject(forKey: key(for: userId))
    }
}
