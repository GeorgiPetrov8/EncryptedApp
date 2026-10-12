import Foundation
import os

/// A managed, protected, bounded store for encrypted media blobs (Bug #23).
///
/// Files live in Application Support so their lifetime is ours to manage, carry the
/// same protection class as the database, and are evicted by age and total size.
///
/// Note on layout: the directory is shared across local accounts and files are named
/// by `mediaId`, which is a server-assigned global identifier. That's deliberate —
/// two accounts that both cache the same blob should share one copy rather than
/// duplicate it. It does mean removal has to be selective; see `remove(paths:)` and
/// the note on `removeAll()`.
final class MediaCacheStore {
    /// Files older than this are evicted regardless of the size budget.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60 // 30 days
    /// Total budget; the least recently modified files go first past this.
    static let maxTotalBytes: Int = 500 * 1024 * 1024 // 500 MB

    private let logger = Logger(subsystem: "com.HyperChat", category: "mediaCache")
    private let fileManager = FileManager.default
    private let directoryName: String

    init(directoryName: String = "encrypted-media") {
        self.directoryName = directoryName
    }

    /// Application Support, not `temporaryDirectory`, and protected on creation so
    /// files written into it inherit the class.
    private var directory: URL {
        get throws {
            let base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = base.appendingPathComponent(directoryName, isDirectory: true)
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
            } else {
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: dir.path
                )
            }
            return dir
        }
    }

    func url(forMediaId mediaId: String) throws -> URL {
        try directory.appendingPathComponent(mediaId)
    }

    func contains(mediaId: String) -> Bool {
        guard let url = try? url(forMediaId: mediaId) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func read(mediaId: String) throws -> Data {
        try Data(contentsOf: url(forMediaId: mediaId))
    }

    /// Writes with an explicit protection class rather than relying solely on
    /// inheritance, since `Data.write` can replace the file wholesale.
    @discardableResult
    func write(_ data: Data, mediaId: String) throws -> URL {
        let target = try url(forMediaId: mediaId)
        try data.write(to: target, options: .completeFileProtectionUntilFirstUserAuthentication)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: target.path
        )
        return target
    }

    func remove(mediaId: String) {
        guard let url = try? url(forMediaId: mediaId) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Unlinks specific files. The caller is responsible for having established that
    /// no other account still references them.
    func remove(paths: [String]) {
        for path in paths {
            try? fileManager.removeItem(atPath: path)
        }
    }

    /// FIX: this is now the account-deletion path only, never logout.
    ///
    /// It used to be called from the logout handler with the comment "so the next
    /// account on this device starts clean" — but the directory is shared, so Alice
    /// logging out wiped Bob's cached attachments too. Bob wasn't logging out of
    /// anything; his files just vanished and had to be re-downloaded. Not permanent
    /// data loss, but it broke the account-isolation invariant the rest of the
    /// codebase holds to, and cost needless network traffic.
    ///
    /// Selective eviction now lives in `MediaEncryptionService.clearCache(ownerUserId:)`.
    /// Keep this for the case where wiping everything really is correct — a full
    /// uninstall-style reset — and for tests.
    func removeAllUnconditionally() {
        guard let dir = try? directory else { return }
        try? fileManager.removeItem(at: dir)
    }

    /// Age-then-size eviction. Runs at startup and after each write.
    func prune(
        maxAge: TimeInterval = MediaCacheStore.maxAge,
        maxTotalBytes: Int = MediaCacheStore.maxTotalBytes
    ) {
        guard let dir = try? directory else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Entry {
            let url: URL
            let modified: Date
            let size: Int
        }

        var entries: [Entry] = []
        let cutoff = Date().addingTimeInterval(-maxAge)

        for url in contents {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0

            if modified < cutoff {
                try? fileManager.removeItem(at: url)
                continue
            }
            entries.append(Entry(url: url, modified: modified, size: size))
        }

        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxTotalBytes else { return }

        // Least recently modified first — the closest proxy for least recently used
        // available without tracking access times ourselves.
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            guard total > maxTotalBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
        logger.debug("Media cache pruned to \(total, privacy: .public) bytes")
    }
}
