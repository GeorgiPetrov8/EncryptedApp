import Foundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics

/// Turns a `PhotosPickerItem` into ready-to-encrypt JPEG bytes: a
/// reasonably-sized full image plus a small thumbnail.
///
/// This is the missing link between the photo picker UI and
/// `MessagingService.sendMedia`. The picker only ever hands SwiftUI a
/// `PhotosPickerItem` *reference* — loading, decoding, resizing, and
/// re-encoding it to something worth encrypting and uploading is entirely
/// this app's responsibility; nothing upstream does it for you.
enum PhotoAttachmentLoader {

    enum LoadError: LocalizedError {
        case noData
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .noData: return "Couldn't read the selected photo."
            case .decodeFailed: return "That photo couldn't be processed."
            }
        }
    }

    /// Caps chosen to comfortably clear the server's 25 MiB upload limit
    /// (`MAX_MEDIA_BYTES` in `HyperChatServer/src/validate.js`) by orders
    /// of magnitude, while still looking sharp on a phone screen. A modern
    /// phone photo can decode to 20+ MB uncompressed at full sensor
    /// resolution; nothing in a chat bubble needs that much detail.
    static let maxDimension: CGFloat = 2048
    static let thumbnailDimension: CGFloat = 240
    private static let jpegQuality: CGFloat = 0.72
    private static let thumbnailJpegQuality: CGFloat = 0.5

    static func loadAndPrepare(_ item: PhotosPickerItem) async throws -> PreparedPhotoAttachment {
        guard let sourceData = try await item.loadTransferable(type: Data.self) else {
            throw LoadError.noData
        }
        guard let imageData = downsample(sourceData, maxDimension: maxDimension, quality: jpegQuality) else {
            throw LoadError.decodeFailed
        }
        guard let thumbnailData = downsample(sourceData, maxDimension: thumbnailDimension, quality: thumbnailJpegQuality) else {
            throw LoadError.decodeFailed
        }
        return PreparedPhotoAttachment(imageData: imageData, thumbnailData: thumbnailData)
    }

    /// Decodes directly to a downsampled `CGImage` via ImageIO rather than
    /// `UIImage(data:)` + `UIGraphicsImageRenderer`.
    /// `CGImageSourceCreateThumbnailAtIndex` with
    /// `kCGImageSourceCreateThumbnailFromImageAlways` decodes straight to
    /// the target size, so peak memory use tracks the *output* dimensions,
    /// not the source photo's — the difference between this and the
    /// UIImage route is easily 10x on a modern 48MP phone camera, which
    /// matters here because this can run while the user is still typing,
    /// not in some background job with memory to spare.
    /// `kCGImageSourceCreateThumbnailWithTransform` bakes in the EXIF
    /// orientation so the result never comes out sideways.
    private static func downsample(_ data: Data, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        // Always re-encoded as JPEG, regardless of the source format (HEIC,
        // PNG, etc.) — one predictable format on the wire and in
        // `MediaItem.mediaType` / `MessageContentType.image`, rather than
        // having to track and later re-derive whatever codec the photo
        // library happened to store the original in.
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        let destinationOptions = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, destinationOptions)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outputData as Data
    }
}

struct PreparedPhotoAttachment {
    let imageData: Data
    let thumbnailData: Data
}
