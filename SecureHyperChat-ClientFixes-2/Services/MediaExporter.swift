import Foundation
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers
import os

/// Short-lived decrypted copies of attachments, for saving, sharing and video
/// playback. Written with complete file protection, deleted as soon as the share
/// sheet or player closes, and swept on the next launch.
enum MediaExporter {
    private static let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "export")

    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SecureHyperChatExports", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        return dir
    }

    static func write(_ data: Data, fileExtension: String, prefix: String) throws -> URL {
        let stamp = Self.stampFormatter.string(from: Date())
        let safeExt = fileExtension.filter { $0.isLetter || $0.isNumber }.prefix(8)
        let url = directory.appendingPathComponent("\(prefix)-\(stamp).\(safeExt.isEmpty ? "bin" : String(safeExt))")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func purge(olderThan age: TimeInterval = 60) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff { try? fm.removeItem(at: file) }
        }
        ProtectedTemp.purge()
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

/// A video picked from the photo library, copied into the protected temp folder
/// (S24 — `temporaryDirectory` has no protection class and the copy could
/// survive a crash).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = ProtectedTemp.url(extension: ext, prefix: "pick")
            try FileManager.default.copyItem(at: received.file, to: destination)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
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

/// Prepares a video for sending.
///
/// FIX (S4): every video is now re-exported with its metadata removed. Videos
/// under 25 MB used to be sent byte-for-byte, carrying GPS coordinates, the
/// phone model and the recording time to the recipient. Small videos use the
/// passthrough preset (no re-encode, fast); larger ones are re-encoded at medium
/// quality to fit the limit.
enum VideoCompressor {
    static let maxBytes = AttachmentPolicy.maxBytes - 64 * 1024

    static func prepare(_ url: URL) async throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        let preset = size <= maxBytes ? AVAssetExportPresetPassthrough : AVAssetExportPresetMediumQuality

        if let data = try await export(url, preset: preset), data.count <= maxBytes {
            return data
        }
        // Passthrough can still be too big (container overhead) — re-encode once.
        if preset == AVAssetExportPresetPassthrough,
           let data = try await export(url, preset: AVAssetExportPresetMediumQuality) {
            guard data.count <= maxBytes else { throw VideoPreparationError.tooLarge }
            return data
        }
        throw VideoPreparationError.tooLarge
    }

    private static func export(_ url: URL, preset: String) async throws -> Data? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoPreparationError.cannotCompress
        }
        let fileType: AVFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        let output = ProtectedTemp.url(extension: fileType == .mp4 ? "mp4" : "mov", prefix: "export")
        defer { MediaExporter.remove(output) }

        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        // Strip location, device and date metadata.
        session.metadata = []
        session.metadataItemFilter = .forSharing()
        await session.export()

        guard session.status == .completed else { throw VideoPreparationError.cannotCompress }
        return try Data(contentsOf: output)
    }
}
