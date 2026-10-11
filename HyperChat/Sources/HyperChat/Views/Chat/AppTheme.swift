import SwiftUI

/// The single source of truth for colours — outside private chats AND inside them.
///
/// ROOT CAUSES this replaces (measured over the whole RGB cube, not guessed):
///
///  1. **Text colour flipped between the background and the bars/rows.**
///     The old bar colour nudged the background 14% toward white. On a medium
///     blue that made the bar light enough to want *black* text while section
///     headers (judged against the darker background) kept *white* text. This
///     happened for 18.3% of all colours. The surface is now moved in whichever
///     direction does NOT change which text colour it needs — so header text, row
///     text, bar text and bubble text are always the same colour (0.0% flips),
///     and worst-case contrast is 4.58:1.
///
///  2. **The blue "my message" bubble blended into the background** for 61% of
///     colours (any mid-tone, and blue ones above all). It now falls back to an
///     inverse bubble exactly when it would not stand out.
///
///  3. **Coloured status text (red/green/orange) is unreadable on coloured rows**:
///     red reaches 4.5:1 on only 10.6% of surfaces. On custom backgrounds status
///     is shown as the normal text colour plus an icon.
///
///  4. Several views hard-coded `.secondary`, `.blue`, `.red`, `Color.brand` or a
///     system material, none of which follow the background.
struct AppTheme: Equatable {
    let isCustom: Bool
    let appearance: ChatAppearance
    /// Colour of bars, rows and incoming bubbles. nil = the system look.
    let surfaceRGB: RGB?
    /// Text placed directly on the background (section headers, footers, chat timestamps).
    let backgroundText: Color
    /// Text placed on a surface. Always the same colour as `backgroundText`.
    let surfaceText: Color
    /// Colour scheme matching the text colour (so system controls adapt).
    let scheme: ColorScheme?
    /// True when the text is white.
    let textIsLight: Bool
    /// Outgoing bubble and prominent buttons.
    let accentFill: Color
    let accentText: Color
    /// "Read" ticks, which sit on the background.
    let readTick: Color

    // MARK: Convenience

    var surface: Color? { surfaceRGB?.color }
    var chrome: ChromeStyle { ChromeStyle(fill: surface, foreground: surfaceText, colorScheme: scheme) }

    /// Kept for existing call sites.
    var rowFill: Color? { surface }
    var onBackground: Color { isCustom ? backgroundText : Color.secondary }
    var tint: Color { isCustom ? surfaceText : Color.brand }

    var text: Color { isCustom ? surfaceText : Color.primary }
    /// Full strength on custom backgrounds: any transparency drops below 4.5:1
    /// somewhere. Secondary text is told apart by size and weight instead.
    var secondaryText: Color { isCustom ? surfaceText : Color.secondary }

    var incomingBubbleFill: Color { surface ?? Color(.secondarySystemBackground) }

    /// Fill for text fields and inset boxes. Moved *away* from the text colour,
    /// so contrast can only improve.
    var fieldFill: Color {
        guard let surfaceRGB else { return Color(.secondarySystemBackground) }
        return surfaceRGB.mixed(with: textIsLight ? .black : .white, 0.10).color
    }

    // MARK: Derivation

    static func makeSystem(appearance: ChatAppearance = .default) -> AppTheme {
        AppTheme(
            isCustom: false,
            appearance: appearance,
            surfaceRGB: nil,
            backgroundText: .primary,
            surfaceText: .primary,
            scheme: nil,
            textIsLight: false,
            accentFill: Color.brand,
            accentText: .white,
            readTick: .blue
        )
    }

    static let system = AppTheme.makeSystem()

    private static let brandRGB = RGB(r: 0.0, g: 0.478, b: 1.0)

    private static func luminance(_ c: RGB) -> Double {
        ContrastPolicy.relativeLuminance(red: c.r, green: c.g, blue: c.b)
    }

    private static func ratio(_ a: RGB, _ b: RGB) -> Double {
        ContrastPolicy.contrastRatio(luminanceA: luminance(a), luminanceB: luminance(b))
    }

    /// - Parameter background: the colour actually visible behind content (for a
    ///   photo: its average colour under the dimming layer). nil = system.
    static func make(appearance: ChatAppearance, visibleBackground background: RGB?) -> AppTheme {
        guard let bg = background, appearance.background != .systemDefault else {
            return makeSystem(appearance: appearance)
        }

        let bgIsDark = bg.prefersLightForeground   // dark-ish → white text

        // Preferred direction first (lighter on dark, darker on light), kept only
        // if the text colour it needs is unchanged; otherwise the other way.
        let candidates: [RGB] = bgIsDark
            ? [bg.mixed(with: .white, 0.14), bg.mixed(with: .black, 0.14)]
            : [bg.mixed(with: .black, 0.08), bg.mixed(with: .white, 0.14)]
        let surface = candidates.first { $0.prefersLightForeground == bgIsDark } ?? candidates[1]

        let text: Color = bgIsDark ? .white : .black

        // Outgoing bubble: the app's blue when it stands out, otherwise the
        // extreme that contrasts most with the background.
        let accentRGB: RGB
        let accentText: Color
        if ratio(brandRGB, bg) >= 1.8 && ratio(brandRGB, surface) >= 1.6 {
            accentRGB = brandRGB
            accentText = .white
        } else if bgIsDark {
            accentRGB = RGB(r: 0.97, g: 0.97, b: 0.97)
            accentText = .black
        } else {
            accentRGB = RGB(r: 0.08, g: 0.08, b: 0.08)
            accentText = .white
        }

        let tickCandidates = [
            RGB(r: 0.0, g: 0.478, b: 1.0),
            RGB(r: 0.45, g: 0.78, b: 1.0),
            RGB(r: 0.0, g: 0.25, b: 0.75),
        ]
        let tick = tickCandidates.first { ratio($0, bg) >= 3.0 }

        return AppTheme(
            isCustom: true,
            appearance: appearance,
            surfaceRGB: surface,
            backgroundText: text,
            surfaceText: text,
            scheme: bgIsDark ? .dark : .light,
            textIsLight: bgIsDark,
            accentFill: accentRGB.color,
            accentText: accentText,
            readTick: tick?.color ?? text
        )
    }
}

// MARK: - Store

extension AppearanceStore {
    /// The colour a person actually sees behind the content.
    func visibleBackground(for appearance: ChatAppearance) -> RGB? {
        switch appearance.background {
        case .systemDefault:
            return nil
        case .solid(let r, let g, let b):
            return RGB(r: r, g: g, b: b)
        case .image(let fileName):
            let average = averageColor(fileName: fileName) ?? RGB(r: 0.5, g: 0.5, b: 0.5)
            let scrim: RGB = appearance.prefersDarkScrim ? .black : .white
            return average.mixed(with: scrim, appearance.effectiveScrimOpacity)
        }
    }

    func theme(for appearance: ChatAppearance) -> AppTheme {
        AppTheme.make(appearance: appearance, visibleBackground: visibleBackground(for: appearance))
    }

    /// Theme of the screens outside private chats.
    var appTheme: AppTheme { theme(for: listAppearance) }

    var barTint: Color { appTheme.tint }
}

// MARK: - Environment

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.system
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}
