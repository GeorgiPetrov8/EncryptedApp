import Foundation

/// FIX (S17): keeps local data out of iCloud / Finder backups.
///
/// The storage key is `ThisDeviceOnly`, so a restored backup can't read message
/// bodies — but usernames, who talked to whom and when, avatars and chat
/// backgrounds were all copied off the phone in clear. Nothing useful comes back
/// from such a backup anyway; the app's own encrypted backup file is the
/// recovery path.
enum BackupExclusion {
    static func exclude(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    /// The database files and every app-managed folder in Application Support.
    static func excludeAppData(databaseURL: URL? = nil) {
        if let databaseURL {
            for suffix in ["", "-wal", "-shm"] {
                exclude(URL(fileURLWithPath: databaseURL.path + suffix))
            }
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return }
        for folder in ["encrypted-media", "avatars", "chat-backgrounds", "protected-tmp"] {
            exclude(base.appendingPathComponent(folder, isDirectory: true))
        }
    }
}

/// A temporary folder that, unlike `temporaryDirectory`, has a file-protection
/// class and isn't backed up (S24). Use it for anything that holds decrypted or
/// not-yet-encrypted content: recordings, picked videos, compressed exports.
enum ProtectedTemp {
    static var directory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("protected-tmp", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            BackupExclusion.exclude(dir)
        }
        return dir
    }

    static func url(extension ext: String, prefix: String = "tmp") -> URL {
        directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
    }

    /// Anything left from a previous run (crash, kill) is removed at launch.
    static func purge() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files { try? fm.removeItem(at: file) }
    }
}
