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

struct AppTheme {
    let appearance: ChatAppearance
    let chrome: ChromeStyle

    static let system = AppTheme(appearance: .default, chrome: .system)

    var isCustom: Bool { chrome.fill != nil }

    /// Text placed directly on the background: section headers and footers.
    var onBackground: Color { isCustom ? appearance.foregroundColor : .secondary }

    /// Fill for form rows — the same surface colour as the header notch.
    var rowFill: Color? { chrome.fill }

    /// Buttons and icons on rows and on the navigation bar.
    var tint: Color { isCustom ? chrome.foreground : .brand }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.system
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension AppearanceStore {
    var appTheme: AppTheme {
        let appearance = listAppearance
        return AppTheme(appearance: appearance, chrome: chrome(for: appearance))
    }

    /// Kept for existing call sites.
    var barTint: Color { appTheme.tint }
}

// MARK: - Screen style

/// Applies the app background to every screen outside a private chat.
struct AppScreenStyle: ViewModifier {
    @EnvironmentObject private var container: AppContainer

    /// Kept for source compatibility; rows are always themed now.
    var adaptsContent: Bool

    func body(content: Content) -> some View {
        let store = container.appearanceStore
        let theme = store.appTheme

        content
            .contentMargins(.top, 12, for: .scrollContent)
            .scrollContentBackground(theme.isCustom ? .hidden : .automatic)
            .background {
                ChatBackgroundView(appearance: theme.appearance) { store.imageURL(fileName: $0) }
            }
            .toolbarBackground(
                theme.isCustom ? AnyShapeStyle(theme.chrome.fill ?? .clear) : AnyShapeStyle(.bar),
                for: .navigationBar
            )
            .toolbarBackground(theme.isCustom ? .visible : .automatic, for: .navigationBar)
            .toolbarColorScheme(theme.chrome.colorScheme, for: .navigationBar)
            // FIX (blue buttons on a blue background): toolbar buttons follow
            // `tint`, not `foregroundStyle` — that's why setting
            // `.foregroundStyle(barTint)` on Cancel/Invite had no effect.
            .tint(theme.tint)
            // Rows are filled with the notch colour, so system text, text
            // fields and chevrons inside them follow the notch's scheme.
            .modifier(SchemeOverride(scheme: theme.chrome.colorScheme))
            .modifier(ReadableValues(enabled: theme.isCustom))
            .toggleStyle(ReadableSwitchStyle())
            .environment(\.appTheme, theme)
    }
}

extension View {
    func appScreenStyle(adaptsContent: Bool = true) -> some View {
        modifier(AppScreenStyle(adaptsContent: adaptsContent))
    }

    /// For a navigation container whose bar must keep the app's colours even
    /// when the pushed screen hides its own bar (the chat screen).
    func appNavigationBarStyle(_ theme: AppTheme) -> some View {
        self
            .toolbarBackground(
                theme.isCustom ? AnyShapeStyle(theme.chrome.fill ?? .clear) : AnyShapeStyle(.bar),
                for: .navigationBar
            )
            .toolbarColorScheme(theme.chrome.colorScheme, for: .navigationBar)
    }
}

// MARK: - Themed section

/// Drop-in replacement for `Section` on themed screens.
///
/// Fills every row with the notch colour and colours the header and footer for
/// the background. Same initialisers as `Section`, so
/// `Section { } header: { } footer: { }` becomes
/// `ThemedSection { } header: { } footer: { }` with no other change.
struct ThemedSection<Content: View, Header: View, Footer: View>: View {
    @Environment(\.appTheme) private var theme

    private let content: Content
    private let header: Header
    private let footer: Footer

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        Section {
            // `Group` hands the modifier to every row individually.
            Group { content }
                .listRowBackground(theme.rowFill)
        } header: {
            header.foregroundStyle(theme.onBackground)
        } footer: {
            footer.foregroundStyle(theme.onBackground)
        }
    }
}

extension ThemedSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension ThemedSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension ThemedSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

extension ThemedSection where Header == Text, Footer == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

// MARK: - Helpers

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

/// `LabeledContent` values ("Username   test123") are grey by default, which
/// drops below readable contrast on a coloured row. On custom backgrounds the
/// value uses the full text colour and is set apart by weight instead.
private struct ReadableValues: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.labeledContentStyle(ReadableLabeledContentStyle())
        } else {
            content
        }
    }
}

private struct ReadableLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            configuration.content
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Switches keep a visible "on" colour whatever the tint is.
private struct ReadableSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(.green)
    }
}
