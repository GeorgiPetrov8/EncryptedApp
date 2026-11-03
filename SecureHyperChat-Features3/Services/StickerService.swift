import Foundation
import UIKit
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import os

/// #7: stickers made from your own photos.
///
/// A sticker is an ordinary image message with a flag (`MediaKeyPayload.sticker`),
/// sent through the existing encrypted media pipeline — no new crypto, no
/// server change. It's drawn without a bubble.
///
/// Making one: the photo is decoded at a bounded size (`ImageSafety`), then
/// either the subject is cut out on the device (Vision's foreground mask, iOS 17,
/// no network) or the photo is cropped to a square. The result is a 512 × 512
/// transparent PNG, at most ~500 KB.
///
/// Your collection is stored per account in Application Support/stickers,
/// protected and excluded from iCloud backup. There's no sticker store, so
/// nothing comes from third parties.
@MainActor
final class StickerService: ObservableObject {
    struct Sticker: Identifiable, Equatable {
        let id: String
        let url: URL
    }

    enum StickerError: LocalizedError {
        case notAnImage
        case noSubject
        case tooMany

        var errorDescription: String? {
            switch self {
            case .notAnImage: return "That photo couldn't be used."
            case .noSubject: return "No clear subject found to cut out. Try \"Square\" instead."
            case .tooMany: return "You have \(StickerService.maxStickers) stickers. Delete some to add more."
            }
        }
    }

    @Published private(set) var stickers: [Sticker] = []

    static let side: CGFloat = 512
    static let maxBytes = 500 * 1024
    static let maxStickers = 200

    private let authService: AuthService
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "stickers")

    init(authService: AuthService) {
        self.authService = authService
    }

    // MARK: Library

    private func directory() -> URL? {
        guard let me = authService.currentUserId,
              let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let root = base.appendingPathComponent("stickers", isDirectory: true)
        let dir = root.appendingPathComponent(me, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            BackupExclusion.exclude(root)
        }
        return dir
    }

    func reload() {
        guard let dir = directory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
              )
        else { stickers = []; return }
        stickers = files
            .filter { $0.pathExtension == "png" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .map { Sticker(id: $0.deletingPathExtension().lastPathComponent, url: $0) }
    }

    @discardableResult
    func add(png: Data) throws -> Sticker {
        reload()
        guard stickers.count < Self.maxStickers else { throw StickerError.tooMany }
        guard let dir = directory() else { throw APIError.notAuthenticated }
        let id = UUID().uuidString
        let url = dir.appendingPathComponent("\(id).png")
        try png.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        reload()
        return Sticker(id: id, url: url)
    }

    /// "Save sticker" on a received one: re-encoded, never stored as received.
    func addReceived(_ data: Data) async throws {
        let png = try await Self.makeSticker(from: data, cutout: false, preserveTransparency: true)
        try add(png: png)
    }

    func delete(_ sticker: Sticker) {
        try? FileManager.default.removeItem(at: sticker.url)
        reload()
    }

    /// Bumps a sticker to the front after it's sent.
    func touch(_ sticker: Sticker) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: sticker.url.path)
        reload()
    }

    func data(for sticker: Sticker) -> Data? {
        try? Data(contentsOf: sticker.url)
    }

    /// Account deletion.
    static func deleteAll(ownerUserId: String) {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent("stickers/\(ownerUserId)", isDirectory: true))
    }

    // MARK: Making a sticker

    /// - cutout: lift the subject (Vision); false = centre square crop.
    /// - preserveTransparency: keep an existing alpha channel (received stickers).
    nonisolated static func makeSticker(from data: Data, cutout: Bool, preserveTransparency: Bool = false) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let source = ImageSafety.downsampledImage(data, maxPixelSize: 1024)?.cgImage else {
                throw StickerError.notAnImage
            }
            let subject: CGImage
            if cutout {
                guard let lifted = try liftSubject(source) else { throw StickerError.noSubject }
                subject = lifted
            } else if preserveTransparency {
                subject = source
            } else {
                subject = squareCrop(source)
            }
            for side in [side, 384, 256] {
                if let png = render(subject, side: side), png.count <= maxBytes { return png }
            }
            throw StickerError.notAnImage
        }.value
    }

    /// Subject cut-out, on device. nil if there's no clear subject.
    nonisolated private static func liftSubject(_ image: CGImage) throws -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
        let buffer = try result.generateMaskedImage(
            ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true
        )
        let ci = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    nonisolated private static func squareCrop(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        return image.cropping(to: rect) ?? image
    }

    /// Fits the image into a transparent `side × side` canvas and encodes PNG.
    nonisolated private static func render(_ image: CGImage, side: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: side, height: side)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(side / w, side / h)
        let drawn = CGSize(width: w * scale, height: h * scale)
        let origin = CGPoint(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: origin, size: drawn))
        }
    }
}
