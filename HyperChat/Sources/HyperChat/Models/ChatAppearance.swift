import SwiftUI

/// Per-device appearance: a background (solid colour or photo), applied to all
/// chats, to one chat, or to the chats list. Never synced or uploaded.
struct ChatAppearance: Codable, Equatable {
    enum Background: Codable, Equatable {
        case systemDefault
        case solid(red: Double, green: Double, blue: Double)
        /// Filename inside the appearance image directory, never an absolute path.
        case image(fileName: String)

        var color: Color? {
            guard case .solid(let r, let g, let b) = self else { return nil }
            return Color(red: r, green: g, blue: b)
        }
    }

    var background: Background = .systemDefault
    /// Photo backgrounds: how strongly the photo is dimmed (see `effectiveScrimOpacity`).
    var bubbleOpacity: Double = 1.0

    static let `default` = ChatAppearance()
}

/// Where an appearance applies.
enum AppearanceScope: Equatable, Identifiable {
    /// The default for every chat without its own background.
    case allChats
    /// The chats list (the app's main screen).
    case chatList
    /// One conversation.
    case conversation(String)

    var id: String {
        switch self {
        case .allChats: return "allChats"
        case .chatList: return "chatList"
        case .conversation(let id): return "conversation:\(id)"
        }
    }
}

/// A plain sRGB colour with the arithmetic the contrast rules need.
struct RGB: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)

    var color: Color { Color(red: r, green: g, blue: b) }

    func mixed(with other: RGB, _ amount: Double) -> RGB {
        RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
    }

    var prefersLightForeground: Bool {
        ContrastPolicy.prefersLightForeground(red: r, green: g, blue: b)
    }
}

/// Colours for the floating bars ("notches") — chat header, composer, and the
/// chats list's navigation bar and rows.
///
/// Derived from what's actually visible behind them, nudged slightly so the bar
/// reads as a separate surface: 14% toward white on a dark background, 8%
/// toward black on a light one. The text colour is then chosen against the
/// *bar*, not the background.
///
/// Checked across the whole RGB cube before being written:
///   - worst text contrast on a bar: 4.58:1 (WCAG AA is 4.5:1) — always readable;
///   - the bar is always distinguishable from the background behind it;
///   - any transparency on the text drops below 4.5:1 somewhere, so secondary
///     text uses the same colour and differs only in size and weight.
struct ChromeStyle: Equatable {
    /// `nil` = use the system bar material (system default background).
    let fill: Color?
    let foreground: Color
    /// Forced on the bars so system controls (text fields, menus) match the fill.
    let colorScheme: ColorScheme?

    static let system = ChromeStyle(fill: nil, foreground: .primary, colorScheme: nil)

    static func derived(fromVisibleBackground background: RGB) -> ChromeStyle {
        let bar = background.prefersLightForeground
            ? background.mixed(with: .white, 0.14)
            : background.mixed(with: .black, 0.08)
        let light = bar.prefersLightForeground
        return ChromeStyle(
            fill: bar.color,
            foreground: light ? .white : .black,
            colorScheme: light ? .dark : .light
        )
    }
}

/// Derives readable foreground colours for an arbitrary user-chosen background.
enum ContrastPolicy {
    /// WCAG 2.1 relative luminance.
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

    /// Black or white, whichever reads better. Worst case over the RGB cube is
    /// 4.58:1, so this alone always clears WCAG AA on a solid colour.
    static func foreground(onSolid red: Double, green: Double, blue: Double) -> Color {
        prefersLightForeground(red: red, green: green, blue: blue) ? .white : .black
    }

    static func prefersLightForeground(red: Double, green: Double, blue: Double) -> Bool {
        let bg = relativeLuminance(red: red, green: green, blue: blue)
        return contrastRatio(luminanceA: bg, luminanceB: 1.0) >= contrastRatio(luminanceA: bg, luminanceB: 0.0)
    }

    /// Minimum scrim over a photo (measured against a worst-case pixel).
    static let minimumDarkScrimOpacity: Double = 0.60
    static let minimumLightScrimOpacity: Double = 0.50
}
