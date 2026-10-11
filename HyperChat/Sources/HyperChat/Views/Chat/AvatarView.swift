import SwiftUI
import CryptoKit

/// A contact's profile picture, with a generated fallback.
///
/// The fallback is a deterministic initial-and-colour avatar derived from the
/// user id (SHA-256, not `hashValue`, which changes on every launch).
struct AvatarView: View {
    let userId: String
    let displayName: String
    let imageData: Data?
    var size: CGFloat = 40
    /// A presence dot, drawn only when online. Nothing is shown when offline —
    /// no grey dot, no "last seen".
    var isOnline: Bool = false
    /// Colour of the ring around the dot — pass the surface the avatar sits on.
    ///
    /// It used to be `Color(.systemBackground)`, which showed as a white or black
    /// ring on a coloured bar.
    var ringColor: Color? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatar
            if isOnline {
                Circle()
                    .fill(.green)
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(
                        Circle().strokeBorder(ringColor ?? Color(.systemBackground), lineWidth: size * 0.06)
                    )
                    .accessibilityLabel("Online")
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var avatar: some View {
        if let imageData, let uiImage = UIImage(data: imageData) {
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
                        // The palette is mid-to-dark only, so white initials are
                        // always readable.
                        .foregroundStyle(.white)
                )
                .frame(width: size, height: size)
        }
    }

    private var initials: String {
        let parts = displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        if parts.isEmpty { return "?" }
        return String(parts).uppercased()
    }

    private var generatedColor: Color {
        let digest = SHA256.hash(data: Data(userId.utf8))
        let bytes = Array(digest)
        return Self.palette[Int(bytes[0]) % Self.palette.count]
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
