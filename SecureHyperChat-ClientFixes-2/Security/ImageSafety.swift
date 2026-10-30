import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Decodes images from other people without letting them exhaust memory.
///
/// FIX (R22): `UIImage(data:)` only reads the header; the pixels are decoded at
/// full size when the image is first drawn. A 300 KB PNG can declare
/// 30 000 × 30 000 pixels (3.6 GB once decoded), and because photos and avatars
/// load as soon as a chat or the chat list opens, the app crashed every time it
/// was opened. Everything received now goes through ImageIO's thumbnail decoder,
/// which never allocates more than the requested output size.
enum ImageSafety {
    /// Images declaring more pixels than this are refused outright.
    static let maxSourcePixels = 50_000_000 // ~ 7 000 × 7 000

    /// Reads the declared size without decoding pixels.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    static func isAcceptable(_ data: Data) -> Bool {
        guard let size = pixelSize(of: data) else { return false }
        return Int(size.width) * Int(size.height) <= maxSourcePixels
    }

    /// A display-sized image, or nil if the data isn't a safe image.
    static func downsampledImage(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard isAcceptable(data),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Re-encodes to a small JPEG (used for received avatars, so the stored file is
    /// safe no matter what the sender put in it).
    static func downsampledJPEG(_ data: Data, maxPixelSize: CGFloat, quality: CGFloat = 0.8) -> Data? {
        guard let image = downsampledImage(data, maxPixelSize: maxPixelSize)?.cgImage else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
