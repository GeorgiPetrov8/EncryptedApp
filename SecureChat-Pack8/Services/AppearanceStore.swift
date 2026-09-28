import SwiftUI
import Combine
import os

/// Stores chat appearance per device.
///
/// Two scopes: a global default, and per-conversation overrides. A
/// conversation with no override inherits the global one, so changing the
/// global background doesn't silently strand conversations the user already
/// customised.
@MainActor
final class AppearanceStore: ObservableObject {

    @Published private(set) var globalAppearance: ChatAppearance = .default
    @Published private(set) var perConversation: [String: ChatAppearance] = [:]

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.HyperChat", category: "appearance")

    private enum Keys {
        static let global = "appearance.global"
        static let perConversation = "appearance.perConversation"
    }

    /// `UserDefaults`, not the encrypted database, on purpose.
    ///
    /// This is cosmetic, non-sensitive, and needed *before* the storage key is
    /// unlocked — the chat list should render with the user's chosen colours
    /// on launch rather than flashing the default and re-theming after Face ID.
    /// The one thing that isn't stored here is the background *image*, which
    /// goes in a protected directory (see `imageDirectory`), because a photo
    /// the user chose is meaningfully more revealing than a hex colour.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Reading

    func appearance(for conversationId: String?) -> ChatAppearance {
        guard let conversationId else { return globalAppearance }
        return perConversation[conversationId] ?? globalAppearance
    }

    func hasOverride(for conversationId: String) -> Bool {
        perConversation[conversationId] != nil
    }

    // MARK: Writing

    func setGlobal(_ appearance: ChatAppearance) {
        globalAppearance = appearance
        persist()
    }

    func setAppearance(_ appearance: ChatAppearance, for conversationId: String) {
        perConversation[conversationId] = appearance
        persist()
    }

    /// Drops a conversation's override so it follows the global setting again.
    func clearOverride(for conversationId: String) {
        guard let removed = perConversation.removeValue(forKey: conversationId) else { return }
        // Delete the backing image too, if this override owned one and no other
        // appearance still references it — otherwise "reset to default" would
        // leave the photo on disk forever.
        if case .image(let fileName) = removed.background {
            deleteImageIfUnreferenced(fileName)
        }
        persist()
    }

    // MARK: Background images

    /// Application Support, protected, and *not* the shared media cache — a
    /// wallpaper is unrelated to message attachments and must not be swept by
    /// `MediaCacheStore.prune()`, which would make backgrounds silently vanish
    /// after 30 days.
    private var imageDirectory: URL {
        get throws {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = base.appendingPathComponent("chat-backgrounds", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
            }
            return dir
        }
    }

    func imageURL(fileName: String) -> URL? {
        try? imageDirectory.appendingPathComponent(fileName)
    }

    /// Saves a chosen photo and returns the filename to store in the appearance.
    ///
    /// Returns a *filename*, never an absolute path: iOS relocates the app
    /// container between installs and OS updates, so a stored absolute path
    /// resolves to nothing after an upgrade.
    func saveBackgroundImage(_ data: Data) throws -> String {
        let fileName = "\(UUID().uuidString).jpg"
        let url = try imageDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        return fileName
    }

    private func deleteImageIfUnreferenced(_ fileName: String) {
        let stillUsed = ([globalAppearance] + perConversation.values).contains { appearance in
            if case .image(let other) = appearance.background { return other == fileName }
            return false
        }
        guard !stillUsed, let url = imageURL(fileName: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Persistence

    private func persist() {
        do {
            let encoder = JSONEncoder()
            defaults.set(try encoder.encode(globalAppearance), forKey: Keys.global)
            defaults.set(try encoder.encode(perConversation), forKey: Keys.perConversation)
        } catch {
            logger.error("Couldn't persist appearance settings")
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Keys.global),
           let decoded = try? decoder.decode(ChatAppearance.self, from: data) {
            globalAppearance = decoded
        }
        if let data = defaults.data(forKey: Keys.perConversation),
           let decoded = try? decoder.decode([String: ChatAppearance].self, from: data) {
            perConversation = decoded
        }
    }
}
