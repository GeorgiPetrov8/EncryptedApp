import SwiftUI
import CryptoKit

/// A contact's profile picture, with a generated fallback.
struct AvatarView: View {
    let userId: String
    let displayName: String
    let imageData: Data?
    var size: CGFloat = 40
    var isOnline: Bool = false
    var ringColor: Color? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatar
            if isOnline {
                Circle()
                    .fill(.green)
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().strokeBorder(ringColor ?? Color(.systemBackground), lineWidth: size * 0.06))
                    .accessibilityLabel("Online")
            }
        }
        .frame(width: size, height: size)
    }

    /// FIX (R22): decoded at display size through ImageIO, never at the file's
    /// declared resolution. Avatars appear in the chat list, so a hostile one
    /// crashed the app on every launch.
    private var decoded: UIImage? {
        guard let imageData else { return nil }
        return AvatarImageCache.image(for: imageData, pixelSize: size * 3)
    }

    @ViewBuilder
    private var avatar: some View {
        if let uiImage = decoded {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(generatedColor)
                .overlay(
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                )
                .frame(width: size, height: size)
        }
    }

    private var initials: String {
        let parts = displayName.split(separator: " ").prefix(2).compactMap { $0.first }
        if parts.isEmpty { return "?" }
        return String(parts).uppercased()
    }

    private var generatedColor: Color {
        let digest = SHA256.hash(data: Data(userId.utf8))
        return Self.palette[Int(Array(digest)[0]) % Self.palette.count]
    }

    private static let palette: [Color] = [
        Color(red: 0.20, green: 0.35, blue: 0.65),
        Color(red: 0.55, green: 0.22, blue: 0.45),
        Color(red: 0.18, green: 0.48, blue: 0.42),
        Color(red: 0.62, green: 0.32, blue: 0.18),
        Color(red: 0.36, green: 0.28, blue: 0.60),
        Color(red: 0.55, green: 0.20, blue: 0.25),
        Color(red: 0.22, green: 0.42, blue: 0.55),
        Color(red: 0.42, green: 0.42, blue: 0.22),
    ]
}

/// Decoded avatars, so the chat list doesn't re-decode on every redraw.
private enum AvatarImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        return c
    }()

    static func image(for data: Data, pixelSize: CGFloat) -> UIImage? {
        let key = "\(SHA256.hash(data: data).description)-\(Int(pixelSize))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = ImageSafety.downsampledImage(data, maxPixelSize: max(pixelSize, 64)) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
