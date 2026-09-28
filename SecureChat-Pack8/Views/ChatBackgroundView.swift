import SwiftUI

/// Renders a chat's background and publishes the foreground colour that is
/// readable on top of it.
///
/// The whole point of this type is that a caller cannot render text over a
/// custom background *without* going through the contrast policy — the
/// readable colour comes out of the same object that draws the background, so
/// "user picked black, text is black, nothing is visible" is not a state the
/// view layer can express.
struct ChatBackgroundView: View {
    let appearance: ChatAppearance
    let imageURL: (String) -> URL?

    var body: some View {
        Group {
            switch appearance.background {
            case .systemDefault:
                Color(.systemBackground)

            case .solid(let r, let g, let b):
                // No scrim: verified across the RGB cube, auto black/white
                // always clears WCAG AA on a solid colour, so the user's
                // chosen colour is shown exactly as picked.
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
                // A photo contains arbitrary pixel values, so no fixed text
                // colour is safe against it. The scrim bounds the luminance
                // underneath; the opacity floor is the measured minimum that
                // keeps WCAG AA against a worst-case pixel.
                scrim
            }
        } else {
            // The file is gone (deleted, or the container moved). Falling back
            // to the system background is the only safe option — rendering
            // nothing would leave text on an undefined surface.
            Color(.systemBackground)
        }
    }

    private var scrim: some View {
        (appearance.prefersDarkScrim ? Color.black : Color.white)
            .opacity(appearance.effectiveScrimOpacity)
    }
}

extension ChatAppearance {

    /// Whether text on this background should be light.
    var prefersLightForeground: Bool {
        switch background {
        case .systemDefault:
            return false // the system handles light/dark itself
        case .solid(let r, let g, let b):
            return ContrastPolicy.prefersLightForeground(red: r, green: g, blue: b)
        case .image:
            return prefersDarkScrim
        }
    }

    /// Photos default to a dark scrim with light text — it reads better over
    /// the majority of photographs, which skew mid-to-bright.
    var prefersDarkScrim: Bool { true }

    /// Never below the measured floor, whatever the user picked.
    var effectiveScrimOpacity: Double {
        let floor = prefersDarkScrim
            ? ContrastPolicy.minimumDarkScrimOpacity
            : ContrastPolicy.minimumLightScrimOpacity
        return max(floor, 1.0 - bubbleOpacity)
    }

    /// The colour body text must use on this background.
    var foregroundColor: Color {
        switch background {
        case .systemDefault:
            return .primary
        case .solid, .image:
            return prefersLightForeground ? .white : .black
        }
    }

    /// A secondary tone that stays legible — plain `.secondary` is resolved
    /// against the *system* background, not a custom one, so on a dark custom
    /// colour it can come out nearly invisible.
    var secondaryForegroundColor: Color {
        switch background {
        case .systemDefault:
            return .secondary
        case .solid, .image:
            return (prefersLightForeground ? Color.white : Color.black).opacity(0.7)
        }
    }

    /// Fill for an incoming bubble. Kept distinct from the background itself,
    /// otherwise bubbles disappear into it on a solid colour.
    var incomingBubbleColor: Color {
        switch background {
        case .systemDefault:
            return Color(.secondarySystemBackground)
        case .solid, .image:
            return (prefersLightForeground ? Color.white : Color.black).opacity(0.18)
        }
    }
}

/// Makes the resolved appearance available to every view in a chat without
/// threading it through each initializer.
private struct ChatAppearanceKey: EnvironmentKey {
    static let defaultValue: ChatAppearance = .default
}

extension EnvironmentValues {
    var chatAppearance: ChatAppearance {
        get { self[ChatAppearanceKey.self] }
        set { self[ChatAppearanceKey.self] = newValue }
    }
}
