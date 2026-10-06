import SwiftUI

/// Applies the chats-list background to every screen outside a private chat
/// (chats list, settings, invitations, recovery, notifications, alarms).
///
/// FIX (icons blending into the background): the navigation bar's colour
/// scheme was only set on the chats list. Opening Settings switched the bar to
/// the default scheme, and when coming back SwiftUI didn't always restore it —
/// so the icons went back to the default colour and disappeared into a dark
/// background. Every screen now applies the same bar style, so there is
/// nothing to restore, and the bar icons get an explicit colour as well.
struct AppScreenStyle: ViewModifier {
    @EnvironmentObject private var container: AppContainer

    /// Forms and plain lists: render their rows in the colour scheme that
    /// matches the background (dark rows on a dark background and vice versa),
    /// so system text stays readable over any custom background.
    var adaptsContent: Bool

    func body(content: Content) -> some View {
        let store = container.appearanceStore
        let appearance = store.listAppearance
        let chrome = store.chrome(for: appearance)
        let isCustom = chrome.fill != nil

        content
            .scrollContentBackground(isCustom ? .hidden : .automatic)
            .background {
                ChatBackgroundView(appearance: appearance) { store.imageURL(fileName: $0) }
            }
            .toolbarBackground(isCustom ? AnyShapeStyle(chrome.fill ?? .clear) : AnyShapeStyle(.bar), for: .navigationBar)
            .toolbarBackground(isCustom ? .visible : .automatic, for: .navigationBar)
            .toolbarColorScheme(chrome.colorScheme, for: .navigationBar)
            .modifier(SchemeOverride(scheme: adaptsContent ? chrome.colorScheme : nil))
            .toggleStyle(ReadableSwitchStyle())
    }
}

extension View {
    func appScreenStyle(adaptsContent: Bool = true) -> some View {
        modifier(AppScreenStyle(adaptsContent: adaptsContent))
    }
}

/// The colour for navigation-bar icons on the current background.
extension AppearanceStore {
    var barTint: Color {
        let chrome = chrome(for: listAppearance)
        return chrome.fill == nil ? .accentColor : chrome.foreground
    }
}

private struct SchemeOverride: ViewModifier {
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

/// Switches keep a visible "on" colour even when the screen tint is white or
/// black (it follows the bar colour on custom backgrounds).
private struct ReadableSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(.green)
    }
}
