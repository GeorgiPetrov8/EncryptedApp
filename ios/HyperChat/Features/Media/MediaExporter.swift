import Foundation
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers
import os

/// Short-lived decrypted copies of attachments, for saving, sharing and
/// video playback. Decrypted media otherwise never touches the disk, so these
/// are written with complete file protection, deleted as soon as the share
/// sheet or player closes, and swept on the next launch if the app died first.
enum MediaExporter {
    private static let logger = Logger(subsystem: "com.HyperChat", category: "export")

    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HyperChatExports", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func write(_ data: Data, fileExtension: String, prefix: String) throws -> URL {
        let stamp = Self.stampFormatter.string(from: Date())
        let url = directory.appendingPathComponent("\(prefix)-\(stamp).\(fileExtension)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes leftovers older than `age` (default: anything from a previous run).
    static func purge(olderThan age: TimeInterval = 60) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff { try? fm.removeItem(at: file) }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// A video picked from the photo library, copied to a temporary file.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = MediaExporter.directory.appendingPathComponent("pick-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

enum VideoPreparationError: LocalizedError {
    case cannotCompress
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .cannotCompress: return "That video couldn't be prepared for sending."
        case .tooLarge: return "That video is too long to send (the limit is 25 MB even after compression). Trim it and try again."
        }
    }
}

/// Makes a video fit the 25 MB attachment limit.
///
/// FIX (videos couldn't be sent): phone videos are usually far over 25 MB,
/// so most of them were rejected outright. Anything over the limit is now
/// re-encoded at medium quality (~480p) first.
enum VideoCompressor {
    /// Leaves room for the AES-GCM overhead so the encrypted upload stays
    /// under the server's limit too.
    static let maxBytes = AttachmentPolicy.maxBytes - 64 * 1024

    static func prepare(_ url: URL) async throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        if size <= maxBytes {
            return try Data(contentsOf: url)
        }

        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw VideoPreparationError.cannotCompress
        }
        let output = MediaExporter.directory.appendingPathComponent("compressed-\(UUID().uuidString).mp4")
        defer { MediaExporter.remove(output) }

        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()

        guard session.status == .completed else { throw VideoPreparationError.cannotCompress }
        let data = try Data(contentsOf: output)
        guard data.count <= maxBytes else { throw VideoPreparationError.tooLarge }
        return data
    }
}
