import UIKit

/// Small in-memory cache of decrypted images, keyed by message id.
///
/// Purely a scroll-performance optimization: without it, `MediaMessageView`
/// would decrypt-and-redecode a photo's bytes every time SwiftUI recreates
/// the view for a row that scrolls off-screen and back — which
/// `LazyVStack` does routinely, and which for a media message means a
/// round trip through `MessagingService.mediaData(for:)` (local-storage
/// AES-GCM decrypt, then either a disk read or a network re-download).
///
/// `NSCache` evicts under memory pressure on its own, so this never needs
/// an explicit size cap tuned per device or a manual clear on logout — the
/// worst case if an entry is evicted mid-session is one extra decrypt, not
/// a correctness problem, since the underlying encrypted bytes are always
/// still on disk (`MediaCacheStore`) or fetchable from the server again.
final class DecryptedMediaCache {
    static let shared = DecryptedMediaCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 60 // roughly a couple of screens' worth of photos
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
