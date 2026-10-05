import SwiftUI

/// Renders a background and is the single source of the colours that are
/// readable on top of it.
struct ChatBackgroundView: View {
    let appearance: ChatAppearance
    let imageURL: (String) -> URL?

    var body: some View {
        Group {
            switch appearance.background {
            case .systemDefault:
                Color(.systemBackground)
            case .solid(let r, let g, let b):
                Color(red: r, green: g, blue: b)
            case .image(let fileName):
                imageBackground(fileName: fileName)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func imageBackground(fileName: String) -> some View {
        if let url = imageURL(fileName), let uiImage = UIImage(contentsOfFile: url.path) {
            ZStack {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                (appearance.prefersDarkScrim ? Color.black : Color.white)
                    .opacity(appearance.effectiveScrimOpacity)
            }
        } else {
            Color(.systemBackground)
        }
    }
}

extension ChatAppearance {
    var prefersLightForeground: Bool {
        switch background {
        case .systemDefault: return false
        case .solid(let r, let g, let b): return ContrastPolicy.prefersLightForeground(red: r, green: g, blue: b)
        case .image: return prefersDarkScrim
        }
    }

    var prefersDarkScrim: Bool { true }

    var effectiveScrimOpacity: Double {
        let floor = prefersDarkScrim ? ContrastPolicy.minimumDarkScrimOpacity : ContrastPolicy.minimumLightScrimOpacity
        return max(floor, 1.0 - bubbleOpacity)
    }

    var foregroundColor: Color {
        switch background {
        case .systemDefault: return .primary
        case .solid, .image: return prefersLightForeground ? .white : .black
        }
    }

    /// Full-strength colour on purpose — see `ChromeStyle`: any transparency
    /// pushes some backgrounds below readable contrast.
    var secondaryForegroundColor: Color {
        switch background {
        case .systemDefault: return .secondary
        case .solid, .image: return foregroundColor
        }
    }

    var incomingBubbleColor: Color {
        switch background {
        case .systemDefault: return Color(.secondarySystemBackground)
        case .solid, .image: return (prefersLightForeground ? Color.white : Color.black).opacity(0.18)
        }
    }

    /// Bar colours for this background. For a photo, `imageAverage` is the
    /// photo's average colour; what's visible is that colour under the scrim.
    func chrome(imageAverage: RGB?) -> ChromeStyle {
        switch background {
        case .systemDefault:
            return .system
        case .solid(let r, let g, let b):
            return .derived(fromVisibleBackground: RGB(r: r, g: g, b: b))
        case .image:
            let average = imageAverage ?? RGB(r: 0.5, g: 0.5, b: 0.5)
            let scrim: RGB = prefersDarkScrim ? .black : .white
            return .derived(fromVisibleBackground: average.mixed(with: scrim, effectiveScrimOpacity))
        }
    }
}

private struct ChatAppearanceKey: EnvironmentKey {
    static let defaultValue: ChatAppearance = .default
}

private struct ChromeStyleKey: EnvironmentKey {
    static let defaultValue: ChromeStyle = .system
}

extension EnvironmentValues {
    var chatAppearance: ChatAppearance {
        get { self[ChatAppearanceKey.self] }
        set { self[ChatAppearanceKey.self] = newValue }
    }

    var chromeStyle: ChromeStyle {
        get { self[ChromeStyleKey.self] }
        set { self[ChromeStyleKey.self] = newValue }
    }
}

/// The floating bar look: rounded, coloured from the background, readable text.
struct NotchStyle: ViewModifier {
    let chrome: ChromeStyle
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .foregroundStyle(chrome.foreground)
            .tint(chrome.fill == nil ? Color.accentColor : chrome.foreground)
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                if let fill = chrome.fill {
                    shape.fill(fill)
                } else {
                    shape.fill(.bar)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .modifier(OptionalColorScheme(scheme: chrome.colorScheme))
    }
}

private struct OptionalColorScheme: ViewModifier {
    let scheme: ColorScheme?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let scheme {
            content.environment(\.colorScheme, scheme)
        } else {
            content
        }
    }
}

extension View {
    func notchStyle(_ chrome: ChromeStyle, cornerRadius: CGFloat = 24) -> some View {
        modifier(NotchStyle(chrome: chrome, cornerRadius: cornerRadius))
    }
}
