import SwiftUI
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import os

/// Stores appearance: a default for all chats, per-chat overrides, and the
/// chats list. `UserDefaults`, because it's cosmetic and must be available
/// before Face ID unlocks the storage key.
///
/// FIX (S35): settings are **per account**. They were shared by every account
/// on the phone (a chat background you picked in one account appeared in the
/// other) and survived account deletion together with the background photos,
/// which can be personal pictures. Now:
///   - keys carry the account id; `setOwner(_:)` switches the active set;
///   - the signed-out screens use the defaults;
///   - `removeAll(ownerUserId:)` deletes an account's settings and any photo
///     no other account uses.
/// The old shared settings are given to the first account that signs in.
@MainActor
final class AppearanceStore: ObservableObject {
    @Published private(set) var globalAppearance: ChatAppearance = .default
    @Published private(set) var perConversation: [String: ChatAppearance] = [:]
    @Published private(set) var listAppearance: ChatAppearance = .default

    private(set) var ownerUserId: String?

    private var averageColors: [String: RGB] = [:]
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "appearance")
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    private enum Keys {
        static let global = "appearance.global"
        static let perConversation = "appearance.perConversation"
        static let list = "appearance.list"
        static let averages = "appearance.imageAverages"
        static let legacyClaimed = "appearance.legacyClaimed"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.averages),
           let decoded = try? JSONDecoder().decode([String: RGB].self, from: data) {
            averageColors = decoded
        }
    }

    private func key(_ base: String, _ owner: String) -> String { "\(base).\(owner)" }

    // MARK: Owner

    /// Call when the signed-in account changes (nil = signed out).
    func setOwner(_ userId: String?) {
        guard userId != ownerUserId || (userId == nil && globalAppearance != .default) else { return }
        ownerUserId = userId
        globalAppearance = .default
        perConversation = [:]
        listAppearance = .default
        guard let userId else { return }
        claimLegacySettingsIfNeeded(for: userId)
        load(owner: userId)
    }

    private func claimLegacySettingsIfNeeded(for owner: String) {
        guard !defaults.bool(forKey: Keys.legacyClaimed) else { return }
        defaults.set(true, forKey: Keys.legacyClaimed)
        for base in [Keys.global, Keys.perConversation, Keys.list] {
            guard let data = defaults.data(forKey: base) else { continue }
            if defaults.data(forKey: key(base, owner)) == nil {
                defaults.set(data, forKey: key(base, owner))
            }
            defaults.removeObject(forKey: base)
        }
    }

    /// Account deletion.
    func removeAll(ownerUserId owner: String) {
        let mine = fileNames(in: loadSet(owner: owner))
        for base in [Keys.global, Keys.perConversation, Keys.list] {
            defaults.removeObject(forKey: key(base, owner))
        }
        var usedElsewhere = Set<String>()
        for otherOwner in allOwners() where otherOwner != owner {
            usedElsewhere.formUnion(fileNames(in: loadSet(owner: otherOwner)))
        }
        for file in mine.subtracting(usedElsewhere) {
            if let url = imageURL(fileName: file) { try? FileManager.default.removeItem(at: url) }
            averageColors[file] = nil
        }
        persistAverages()
        if ownerUserId == owner { setOwner(nil) }
    }

    private func allOwners() -> Set<String> {
        let prefix = Keys.global + "."
        return Set(defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) })
    }

    // MARK: Reading

    func appearance(for conversationId: String?) -> ChatAppearance {
        guard let conversationId else { return globalAppearance }
        return perConversation[conversationId] ?? globalAppearance
    }

    func appearance(scope: AppearanceScope) -> ChatAppearance {
        switch scope {
        case .allChats: return globalAppearance
        case .chatList: return listAppearance
        case .conversation(let id): return appearance(for: id)
        }
    }

    func hasOverride(for conversationId: String) -> Bool {
        perConversation[conversationId] != nil
    }

    func hasOverride(scope: AppearanceScope) -> Bool {
        switch scope {
        case .allChats: return false
        case .chatList: return listAppearance != .default
        case .conversation(let id): return hasOverride(for: id)
        }
    }

    func chrome(for appearance: ChatAppearance) -> ChromeStyle {
        var average: RGB?
        if case .image(let fileName) = appearance.background {
            average = averageColor(fileName: fileName)
        }
        return appearance.chrome(imageAverage: average)
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

    func set(_ appearance: ChatAppearance, scope: AppearanceScope) {
        switch scope {
        case .allChats: setGlobal(appearance)
        case .chatList: listAppearance = appearance; persist()
        case .conversation(let id): setAppearance(appearance, for: id)
        }
    }

    func clearOverride(for conversationId: String) {
        guard let removed = perConversation.removeValue(forKey: conversationId) else { return }
        persist()
        deleteImageIfUnreferenced(removed)
    }

    func clear(scope: AppearanceScope) {
        switch scope {
        case .allChats:
            let removed = globalAppearance
            globalAppearance = .default
            persist()
            deleteImageIfUnreferenced(removed)
        case .chatList:
            let removed = listAppearance
            listAppearance = .default
            persist()
            deleteImageIfUnreferenced(removed)
        case .conversation(let id):
            clearOverride(for: id)
        }
    }

    // MARK: Background images

    private var imageDirectory: URL {
        get throws {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let dir = base.appendingPathComponent("chat-backgrounds", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
                BackupExclusion.exclude(dir)
            }
            return dir
        }
    }

    func imageURL(fileName: String) -> URL? {
        // Only our own UUID file names — never a path from anywhere else.
        guard fileName.hasSuffix(".jpg"), UUID(uuidString: String(fileName.dropLast(4))) != nil else { return nil }
        return try? imageDirectory.appendingPathComponent(fileName)
    }

    func saveBackgroundImage(_ data: Data) throws -> String {
        let fileName = "\(UUID().uuidString).jpg"
        guard let url = imageURL(fileName: fileName) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        _ = averageColor(fileName: fileName)
        return fileName
    }

    func averageColor(fileName: String) -> RGB? {
        if let cached = averageColors[fileName] { return cached }
        guard let url = imageURL(fileName: fileName), let image = CIImage(contentsOf: url) else { return nil }
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let rgb = RGB(r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255)
        averageColors[fileName] = rgb
        persistAverages()
        return rgb
    }

    private func fileNames(in set: (global: ChatAppearance, per: [String: ChatAppearance], list: ChatAppearance)) -> Set<String> {
        Set(([set.global, set.list] + Array(set.per.values)).compactMap {
            if case .image(let file) = $0.background { return file }
            return nil
        })
    }

    private func deleteImageIfUnreferenced(_ removed: ChatAppearance) {
        guard case .image(let fileName) = removed.background else { return }
        var used = fileNames(in: (globalAppearance, perConversation, listAppearance))
        for owner in allOwners() where owner != ownerUserId {
            used.formUnion(fileNames(in: loadSet(owner: owner)))
        }
        guard !used.contains(fileName), let url = imageURL(fileName: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
        averageColors[fileName] = nil
        persistAverages()
    }

    // MARK: Persistence

    private func persist() {
        guard let owner = ownerUserId else { return }
        do {
            let encoder = JSONEncoder()
            defaults.set(try encoder.encode(globalAppearance), forKey: key(Keys.global, owner))
            defaults.set(try encoder.encode(perConversation), forKey: key(Keys.perConversation, owner))
            defaults.set(try encoder.encode(listAppearance), forKey: key(Keys.list, owner))
        } catch {
            logger.error("Couldn't persist appearance settings")
        }
    }

    private func persistAverages() {
        if let data = try? JSONEncoder().encode(averageColors) {
            defaults.set(data, forKey: Keys.averages)
        }
    }

    private func loadSet(owner: String) -> (global: ChatAppearance, per: [String: ChatAppearance], list: ChatAppearance) {
        let decoder = JSONDecoder()
        let global = defaults.data(forKey: key(Keys.global, owner))
            .flatMap { try? decoder.decode(ChatAppearance.self, from: $0) } ?? .default
        let per = defaults.data(forKey: key(Keys.perConversation, owner))
            .flatMap { try? decoder.decode([String: ChatAppearance].self, from: $0) } ?? [:]
        let list = defaults.data(forKey: key(Keys.list, owner))
            .flatMap { try? decoder.decode(ChatAppearance.self, from: $0) } ?? .default
        return (global, per, list)
    }

    private func load(owner: String) {
        let set = loadSet(owner: owner)
        globalAppearance = set.global
        perConversation = set.per
        listAppearance = set.list
    }
}
