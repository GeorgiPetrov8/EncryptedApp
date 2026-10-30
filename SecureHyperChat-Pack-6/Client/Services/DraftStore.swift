import Foundation

/// Unsent text per conversation (#9).
///
/// In the Keychain (this device only, never in backups), because a draft is
/// message plaintext. Per account.
final class DraftStore {
    static let maxLength = 4_000
    private let keychain = KeychainStore(service: "com.HyperChat.drafts")

    private func key(_ conversationId: String, _ owner: String) -> String {
        KeychainStore.namespaced("draft.\(conversationId)", userId: owner)
    }

    func load(conversationId: String, ownerUserId: String) -> String {
        keychain.loadIfPresent(key: key(conversationId, ownerUserId))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func save(_ text: String, conversationId: String, ownerUserId: String) {
        let trimmed = String(text.prefix(Self.maxLength))
        if trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keychain.delete(key: key(conversationId, ownerUserId))
        } else {
            try? keychain.save(key: key(conversationId, ownerUserId), data: Data(trimmed.utf8))
        }
    }

    func clear(conversationId: String, ownerUserId: String) {
        keychain.delete(key: key(conversationId, ownerUserId))
    }

    func removeAll(ownerUserId: String) {
        keychain.deleteAll(forUserId: ownerUserId)
    }
}
