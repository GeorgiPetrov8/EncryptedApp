import SwiftUI

extension Color {
    /// The app's own blue, independent of the environment `.tint`.
    ///
    /// FIX (white text / white buttons): the chats list tints its navigation
    /// stack with the bar colour (white on a dark background) so its back
    /// buttons stay readable. `Color.accentColor` follows that tint, so
    /// everything built from it — your own message bubbles, the play button
    /// of voice messages, buttons in sheets — turned white on white. Anything
    /// that must stay blue now uses `.brand` instead.
    static let brand = Color(uiColor: .systemBlue)
}

/// Applies the app background to every screen outside a private chat
/// (chats list, settings, invitations, recovery, notifications, alarms,
/// new chat, shared pad, verify security, background options).
struct AppScreenStyle: ViewModifier {
    @EnvironmentObject private var container: AppContainer

    /// Forms and plain lists: render rows in the colour scheme that matches
    /// the background, so system text stays readable on any background.
    var adaptsContent: Bool

    func body(content: Content) -> some View {
        let store = container.appearanceStore
        let appearance = store.listAppearance
        let chrome = store.chrome(for: appearance)
        let isCustom = chrome.fill != nil

        content
            // FIX: room between the top bar and the first row.
            .contentMargins(.top, 12, for: .scrollContent)
            .scrollContentBackground(isCustom ? .hidden : .automatic)
            .background {
                ChatBackgroundView(appearance: appearance) { store.imageURL(fileName: $0) }
            }
            .toolbarBackground(isCustom ? AnyShapeStyle(chrome.fill ?? .clear) : AnyShapeStyle(.bar), for: .navigationBar)
            .toolbarBackground(isCustom ? .visible : .automatic, for: .navigationBar)
            .toolbarColorScheme(chrome.colorScheme, for: .navigationBar)
            .modifier(SchemeOverride(scheme: adaptsContent ? chrome.colorScheme : nil))
            .toggleStyle(ReadableSwitchStyle())
            // FIX: buttons inside the screen are always blue, never the
            // white bar colour inherited from the chats list.
            .tint(Color.brand)
    }
}

extension View {
    func appScreenStyle(adaptsContent: Bool = true) -> some View {
        modifier(AppScreenStyle(adaptsContent: adaptsContent))
    }
}

extension AppearanceStore {
    /// Colour for navigation-bar icons on the current app background.
    var barTint: Color {
        let chrome = chrome(for: listAppearance)
        return chrome.fill == nil ? .brand : chrome.foreground
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

private struct ReadableSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(.green)
    }
}
