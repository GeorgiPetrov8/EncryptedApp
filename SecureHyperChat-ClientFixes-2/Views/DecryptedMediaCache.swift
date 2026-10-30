import UIKit

/// Small in-memory cache of decrypted images, keyed by message id.
///
/// FIX (S23): emptied on logout and whenever the app locks or goes to the
/// background. Before, decrypted photos stayed in memory behind the lock screen
/// and across account switches.
final class DecryptedMediaCache {
    static let shared = DecryptedMediaCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 60
        // Keys are message ids; images are display-sized (see ImageSafety), so the
        // cost limit is a real bound.
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forKey key: String) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        cache.setObject(image, forKey: key as NSString, cost: Int(pixels * 4))
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
