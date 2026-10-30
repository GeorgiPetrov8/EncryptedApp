import Foundation

/// The photos / videos / documents half of a backup (R4).
///
/// Separate from the main `.hcbackup` because media can be gigabytes and the
/// main backup is built in memory. This file is written and read **one
/// attachment at a time**, so its size is limited only by free storage.
///
/// Every attachment is stored exactly as it sits in this phone's media cache:
/// already AES-GCM encrypted with its own random key. Those keys travel only
/// inside the messages, i.e. inside the password-protected main backup — so
/// this file is useless on its own and needs no password of its own. What it
/// does reveal to whoever has the file: how many attachments and their sizes.
///
/// Layout
///   "HCMB" | version u8 | userIdLength u16 BE | userId (UTF-8)
///   repeated:  0x01 | mediaId (36 ASCII) | length u64 BE | encrypted bytes
///   end:       0x00
enum MediaBackupFile {
    static let magic = Data("HCMB".utf8)
    static let version: UInt8 = 1
    /// Larger than any single attachment the app can send (25 MB).
    static let maxEntryBytes: UInt64 = 200 * 1024 * 1024

    enum Error: LocalizedError {
        case notAMediaBackup
        case unsupportedVersion
        case otherAccount
        case corrupted

        var errorDescription: String? {
            switch self {
            case .notAMediaBackup: return "This file isn't a SecureHyperChat media backup."
            case .unsupportedVersion: return "This media backup was made by a newer version of SecureHyperChat."
            case .otherAccount: return "This media backup belongs to a different account."
            case .corrupted: return "The media backup is damaged."
            }
        }
    }

    // MARK: Writing

    final class Writer {
        private let handle: FileHandle
        private(set) var count = 0
        private(set) var bytes: UInt64 = 0

        init(url: URL, userId: String) throws {
            FileManager.default.createFile(
                atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            handle = try FileHandle(forWritingTo: url)
            var header = MediaBackupFile.magic
            header.append(MediaBackupFile.version)
            let id = Data(userId.utf8)
            header.append(contentsOf: withUnsafeBytes(of: UInt16(id.count).bigEndian) { Array($0) })
            header.append(id)
            try handle.write(contentsOf: header)
        }

        func add(mediaId: String, encrypted: Data) throws {
            guard SafeIdentifier.isMediaId(mediaId) else { return }
            var record = Data([0x01])
            record.append(Data(mediaId.lowercased().utf8))
            record.append(contentsOf: withUnsafeBytes(of: UInt64(encrypted.count).bigEndian) { Array($0) })
            try handle.write(contentsOf: record)
            try handle.write(contentsOf: encrypted)
            count += 1
            bytes += UInt64(encrypted.count)
        }

        func finish() throws {
            try handle.write(contentsOf: Data([0x00]))
            try handle.synchronize()
            try handle.close()
        }
    }

    // MARK: Reading

    /// Calls `handler` for every attachment, one at a time.
    static func read(url: URL, expectedUserId: String, handler: (String, Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        func readExactly(_ n: Int) throws -> Data {
            guard n >= 0 else { throw Error.corrupted }
            if n == 0 { return Data() }
            guard let data = try handle.read(upToCount: n), data.count == n else { throw Error.corrupted }
            return data
        }
        func readUInt(_ n: Int) throws -> UInt64 {
            try readExactly(n).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        guard (try? readExactly(4)) == magic else { throw Error.notAMediaBackup }
        guard try readExactly(1).first == version else { throw Error.unsupportedVersion }
        let idLength = Int(try readUInt(2))
        guard idLength <= 128,
              let userId = String(data: try readExactly(idLength), encoding: .utf8) else { throw Error.corrupted }
        guard userId == expectedUserId else { throw Error.otherAccount }

        while true {
            guard let tag = try readExactly(1).first else { throw Error.corrupted }
            if tag == 0x00 { return }
            guard tag == 0x01 else { throw Error.corrupted }
            guard let mediaId = String(data: try readExactly(36), encoding: .ascii),
                  SafeIdentifier.isMediaId(mediaId) else { throw Error.corrupted }
            let length = try readUInt(8)
            guard length > 0, length <= maxEntryBytes else { throw Error.corrupted }
            try handler(mediaId, try readExactly(Int(length)))
        }
    }
}
