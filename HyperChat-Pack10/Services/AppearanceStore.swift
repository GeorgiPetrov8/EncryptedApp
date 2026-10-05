import SwiftUI
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import os

/// Stores appearance per device: a default for all chats, per-chat overrides,
/// and the chats list. `UserDefaults`, because it's cosmetic and must be
/// available before Face ID unlocks the storage key.
@MainActor
final class AppearanceStore: ObservableObject {
    @Published private(set) var globalAppearance: ChatAppearance = .default
    @Published private(set) var perConversation: [String: ChatAppearance] = [:]
    @Published private(set) var listAppearance: ChatAppearance = .default

    /// Average colour per background photo, for deriving bar colours.
    private var averageColors: [String: RGB] = [:]

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.HyperChat", category: "appearance")
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    private enum Keys {
        static let global = "appearance.global"
        static let perConversation = "appearance.perConversation"
        static let list = "appearance.list"
        static let averages = "appearance.imageAverages"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
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

    /// Bar colours for an appearance, including photo backgrounds.
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
            }
            return dir
        }
    }

    func imageURL(fileName: String) -> URL? {
        try? imageDirectory.appendingPathComponent(fileName)
    }

    func saveBackgroundImage(_ data: Data) throws -> String {
        let fileName = "\(UUID().uuidString).jpg"
        let url = try imageDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        _ = averageColor(fileName: fileName) // compute once, now
        return fileName
    }

    /// The photo's average colour, computed once with Core Image and cached.
    func averageColor(fileName: String) -> RGB? {
        if let cached = averageColors[fileName] { return cached }
        guard let url = imageURL(fileName: fileName),
              let image = CIImage(contentsOf: url) else { return nil }

        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        let rgb = RGB(r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255)
        averageColors[fileName] = rgb
        if let data = try? JSONEncoder().encode(averageColors) {
            defaults.set(data, forKey: Keys.averages)
        }
        return rgb
    }

    private func deleteImageIfUnreferenced(_ removed: ChatAppearance) {
        guard case .image(let fileName) = removed.background else { return }
        let stillUsed = ([globalAppearance, listAppearance] + perConversation.values).contains {
            if case .image(let other) = $0.background { return other == fileName }
            return false
        }
        guard !stillUsed, let url = imageURL(fileName: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
        averageColors[fileName] = nil
    }

    // MARK: Persistence

    private func persist() {
        do {
            let encoder = JSONEncoder()
            defaults.set(try encoder.encode(globalAppearance), forKey: Keys.global)
            defaults.set(try encoder.encode(perConversation), forKey: Keys.perConversation)
            defaults.set(try encoder.encode(listAppearance), forKey: Keys.list)
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
        if let data = defaults.data(forKey: Keys.list),
           let decoded = try? decoder.decode(ChatAppearance.self, from: data) {
            listAppearance = decoded
        }
        if let data = defaults.data(forKey: Keys.averages),
           let decoded = try? decoder.decode([String: RGB].self, from: data) {
            averageColors = decoded
        }
    }
}
