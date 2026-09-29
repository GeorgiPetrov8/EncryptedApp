import SwiftUI
import CryptoKit

/// A contact's profile picture, with a generated fallback (feature #4).
///
/// The fallback is not a grey silhouette. A deterministic initial-and-colour
/// avatar makes conversations distinguishable at a glance even when nobody has
/// set a picture, which is the normal state early on. The colour is derived
/// from the user id, so it's stable across devices and launches — the same
/// person is always the same colour.
struct AvatarView: View {
    let userId: String
    let displayName: String
    let imageData: Data?
    var size: CGFloat = 40
    /// Feature #5: a presence ring, drawn only when online. Nothing is shown
    /// when offline — no grey dot, no "last seen".
    var isOnline: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatar
            if isOnline {
                Circle()
                    .fill(.green)
                    .frame(width: size * 0.28, height: size * 0.28)
                    // A ring in the surrounding colour keeps the dot legible
                    // against both the avatar and any custom background.
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: size * 0.06))
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
                        // White on a generated colour: the palette below is
                        // constrained to mid-to-dark hues precisely so this
                        // one text colour is always readable, rather than
                        // needing a per-colour contrast check here.
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

    /// Derived from a hash of the user id rather than from `hashValue`.
    ///
    /// Swift's `hashValue` is seeded per process, so it produces a *different*
    /// number on every launch — the same contact would change colour each time
    /// the app restarted. SHA-256 is stable across launches and devices.
    private var generatedColor: Color {
        let digest = SHA256.hash(data: Data(userId.utf8))
        let bytes = Array(digest)
        let firstByte = bytes[0]
        let index = Int(firstByte) % Self.palette.count
        return Self.palette[index]
    }

    /// Mid-to-dark hues only, so white initials always have adequate contrast.
    /// Deliberately not a full hue wheel — pale yellows and light greens would
    /// need dark text, which would mean per-colour branching here.
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
