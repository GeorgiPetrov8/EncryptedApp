import UIKit
import ImageIO

/// Downloads and decodes GIFs into animated images, with a memory cache.
///
/// FIX (S42):
///   - https only, through an ephemeral session (no cookies, no disk cache —
///     the GIF provider can't set or read anything on the phone);
///   - the size of the *decoded* animation is bounded (64 MB of pixels), not
///     just the file and frame count: 150 frames × 480 px used to be ~140 MB,
///     and a few of those in one chat ended the app;
///   - the declared canvas size is checked before decoding.
@MainActor
final class GIFLoader {
    static let shared = GIFLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private static let maxBytes = 8 * 1024 * 1024
    private static let maxFrames = 150
    private static let maxDecodedBytes = 64 * 1024 * 1024
    private static let maxCanvasPixels = 4_000 * 4_000

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["Referer": ""]
        return URLSession(configuration: config)
    }()

    private init() {
        cache.totalCostLimit = 60 * 1024 * 1024
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let (data, response) = try? await Self.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= Self.maxBytes else { return nil }

        let image = await Task.detached(priority: .userInitiated) {
            Self.decode(data, maxPixelSize: maxPixelSize)
        }.value
        if let image {
            let frames = max(image.images?.count ?? 1, 1)
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4) * frames
            cache.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }

    private nonisolated static func decode(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int,
           w * h > maxCanvasPixels {
            return nil
        }

        let count = min(CGImageSourceGetCount(source), maxFrames)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard count > 1 else {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: frame)
        }

        var frames: [UIImage] = []
        var duration: Double = 0
        var decodedBytes = 0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            decodedBytes += frame.width * frame.height * 4
            if decodedBytes > maxDecodedBytes { break }
            frames.append(UIImage(cgImage: frame))
            duration += frameDelay(source, index)
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }

    private nonisolated static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0.1
        return delay < 0.02 ? 0.1 : delay
    }
}
