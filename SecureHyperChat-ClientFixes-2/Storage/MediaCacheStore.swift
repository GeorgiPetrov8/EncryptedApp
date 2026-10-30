import Foundation
import os

/// Store for encrypted media blobs (Bug #23).
///
/// Files live in Application Support, carry the database's protection class and
/// are excluded from iCloud backup. The directory is shared across local
/// accounts and files are named by the server-assigned `mediaId`.
///
/// FIX (R4): no automatic deletion any more. The agreed rule is that the phone
/// keeps the user's media until the user deletes it; the server only relays. The
/// old 30-day / 500 MB eviction deleted the only copy of photos the server had
/// already discarded. `prune()` is kept for source compatibility and only
/// removes stray partial files.
///
/// FIX (S31): every path is built from a validated UUID and checked to stay
/// inside this directory.
final class MediaCacheStore {
    enum CacheError: LocalizedError {
        case invalidMediaId
        var errorDescription: String? { "This attachment has an invalid identifier." }
    }

    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "mediaCache")
    private let fileManager = FileManager.default
    private let directoryName: String

    init(directoryName: String = "encrypted-media") {
        self.directoryName = directoryName
    }

    private var directory: URL {
        get throws {
            let base = try fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let dir = base.appendingPathComponent(directoryName, isDirectory: true)
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
                BackupExclusion.exclude(dir)
            }
            return dir
        }
    }

    /// Only a well-formed UUID becomes a file name, and the result must resolve
    /// inside the cache directory.
    func url(forMediaId mediaId: String) throws -> URL {
        guard SafeIdentifier.isMediaId(mediaId) else { throw CacheError.invalidMediaId }
        let dir = try directory
        let url = dir.appendingPathComponent(mediaId.lowercased(), isDirectory: false)
        guard isInside(url, dir) else { throw CacheError.invalidMediaId }
        return url
    }

    private func isInside(_ url: URL, _ dir: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = dir.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return child.hasPrefix(parent)
    }

    func contains(mediaId: String) -> Bool {
        guard let url = try? url(forMediaId: mediaId) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func read(mediaId: String) throws -> Data {
        try Data(contentsOf: url(forMediaId: mediaId))
    }

    @discardableResult
    func write(_ data: Data, mediaId: String) throws -> URL {
        let target = try url(forMediaId: mediaId)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return target
    }

    func remove(mediaId: String) {
        guard let url = try? url(forMediaId: mediaId) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Unlinks specific files — but only paths that really are inside this
    /// directory. A path stored from a malicious `mediaId` before this fix
    /// (e.g. `.../encrypted-media/../HyperChat.sqlite`) is ignored.
    func remove(paths: [String]) {
        guard let dir = try? directory else { return }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard isInside(url, dir), SafeIdentifier.isMediaId(url.lastPathComponent) else {
                logger.error("Refused to delete a media path outside the cache")
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Account-deletion / full reset only.
    func removeAllUnconditionally() {
        guard let dir = try? directory else { return }
        try? fileManager.removeItem(at: dir)
    }

    /// No longer evicts user media (see the type comment). Removes only files
    /// whose name isn't a media id — leftovers of interrupted atomic writes.
    func prune() {
        guard let dir = try? directory,
              let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in contents where !SafeIdentifier.isMediaId(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Total size, for a storage screen.
    func totalBytes() -> Int {
        guard let dir = try? directory,
              let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return contents.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
