import SwiftUI

/// Per-device chat appearance: a custom background, either a solid colour or a
/// photo, applied globally or per-conversation.
///
/// Deliberately device-local — never synced, never sent to the server. It is a
/// cosmetic preference with no value to the peer, and syncing it would mean
/// uploading a user's chosen photo, which is a privacy cost for no benefit.
struct ChatAppearance: Codable, Equatable {

    enum Background: Codable, Equatable {
        case systemDefault
        /// Stored as components rather than `Color`, which isn't `Codable`.
        case solid(red: Double, green: Double, blue: Double)
        /// Filename inside the appearance image directory (see
        /// `AppearanceStore`), not an absolute path — absolute paths break
        /// when iOS relocates the app container between launches.
        case image(fileName: String)

        var color: Color? {
            guard case .solid(let r, let g, let b) = self else { return nil }
            return Color(red: r, green: g, blue: b)
        }
    }

    var background: Background = .systemDefault

    /// How strongly bubbles stand out from the background. Exposed because the
    /// right amount is genuinely taste-dependent over a photo, and because a
    /// user who picks a busy image needs a way to make text readable without
    /// abandoning the image.
    var bubbleOpacity: Double = 1.0

    static let `default` = ChatAppearance()
}

/// Derives readable foreground colours for an arbitrary user-chosen background.
///
/// This exists because "let the user pick any colour" and "the app must remain
/// readable" are in direct conflict unless something enforces contrast. Black
/// text on a black background is the obvious failure, but the subtle ones —
/// mid-grey, muddy teal — are the ones a user will actually stumble into.
enum ContrastPolicy {

    /// WCAG 2.1 relative luminance. The odd-looking constants are the sRGB
    /// gamma curve and the CIE luminance weights; they are not tunable.
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    static func contrastRatio(luminanceA: Double, luminanceB: Double) -> Double {
        let hi = max(luminanceA, luminanceB)
        let lo = min(luminanceA, luminanceB)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Black or white, whichever reads better on this background.
    ///
    /// Checked across the whole RGB cube before being written: the worst case
    /// is rgb(75, 125, 135) at **4.58:1**, which still clears WCAG AA (4.5:1).
    /// So for a solid colour this rule alone is sufficient and no scrim is
    /// needed — the app can honour the user's exact colour choice.
    static func foreground(onSolid red: Double, green: Double, blue: Double) -> Color {
        let bg = relativeLuminance(red: red, green: green, blue: blue)
        let onWhite = contrastRatio(luminanceA: bg, luminanceB: 1.0)
        let onBlack = contrastRatio(luminanceA: bg, luminanceB: 0.0)
        return onWhite >= onBlack ? .white : .black
    }

    /// Whether this background is dark enough that white text suits it.
    static func prefersLightForeground(red: Double, green: Double, blue: Double) -> Bool {
        foreground(onSolid: red, green: green, blue: blue) == .white
    }

    /// Minimum scrim opacity for a **photo** background.
    ///
    /// A photo can contain any pixel value, so no single text colour is safe
    /// against it — the auto black/white rule above only works when the
    /// background is one known colour. A scrim (a semi-transparent layer
    /// between photo and text) bounds the possible luminance underneath.
    ///
    /// Computed against the adversarial worst case, a pure-white pixel under a
    /// dark scrim and a pure-black pixel under a light one:
    ///
    ///   | opacity | dark scrim + white text | light scrim + black text |
    ///   |---------|-------------------------|--------------------------|
    ///   | 0.40    | 2.85:1  fail            | 3.66:1  fail             |
    ///   | 0.50    | 3.95:1  fail            | 5.32:1  **pass**         |
    ///   | 0.60    | 5.74:1  **pass**        | 7.37:1  pass             |
    ///
    /// Hence 0.60 dark / 0.50 light as the floors. The UI may offer *more*
    /// scrim, never less.
    static let minimumDarkScrimOpacity: Double = 0.60
    static let minimumLightScrimOpacity: Double = 0.50
}
