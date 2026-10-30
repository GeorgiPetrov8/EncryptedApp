import Foundation

/// FIX (S34): local block list.
///
/// Declining an invitation deleted the chat, so the same person could invite
/// again immediately — forever, with a notification each time. A blocked user's
/// envelopes are acknowledged and dropped silently: no chat, no notification,
/// no read receipts. Per local account.
final class BlockListStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ owner: String) -> String { "blocked.\(owner)" }

    func blocked(ownerUserId: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key(ownerUserId)) ?? [])
    }

    func isBlocked(_ userId: String, ownerUserId: String) -> Bool {
        blocked(ownerUserId: ownerUserId).contains(userId)
    }

    func block(_ userId: String, ownerUserId: String) {
        var set = blocked(ownerUserId: ownerUserId)
        set.insert(userId)
        defaults.set(Array(set), forKey: key(ownerUserId))
    }

    func unblock(_ userId: String, ownerUserId: String) {
        var set = blocked(ownerUserId: ownerUserId)
        set.remove(userId)
        defaults.set(Array(set), forKey: key(ownerUserId))
    }

    func removeAll(ownerUserId: String) {
        defaults.removeObject(forKey: key(ownerUserId))
    }
}
