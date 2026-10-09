import SwiftUI

extension Color {
    /// The app's own blue, independent of the environment `.tint`.
    static let brand = Color(uiColor: .systemBlue)
}

// MARK: - Screen style

/// Applies the app background and theme to every screen outside a private chat.
///
/// Rows, bars and headers all come from one `AppTheme`, so the text colour is the
/// same on the background, on rows and on the navigation bar.
struct AppScreenStyle: ViewModifier {
    @EnvironmentObject private var container: AppContainer

    /// Kept for source compatibility; screens are always themed now.
    var adaptsContent: Bool = true

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
                theme.surface.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.bar),
                for: .navigationBar
            )
            .toolbarBackground(theme.isCustom ? .visible : .automatic, for: .navigationBar)
            .toolbarColorScheme(theme.scheme, for: .navigationBar)
            // Toolbar buttons follow `tint`, not `foregroundStyle`.
            .tint(theme.tint)
            .modifier(SchemeOverride(scheme: theme.scheme))
            .modifier(ReadableValues(enabled: theme.isCustom))
            .toggleStyle(ReadableSwitchStyle())
            .environment(\.appTheme, theme)
    }
}

extension View {
    func appScreenStyle(adaptsContent: Bool = true) -> some View {
        modifier(AppScreenStyle(adaptsContent: adaptsContent))
    }

    /// Keeps the navigation bar's colours on a container whose pushed screen
    /// hides its own bar (the chat screen).
    func appNavigationBarStyle(_ theme: AppTheme) -> some View {
        self
            .toolbarBackground(
                theme.surface.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.bar),
                for: .navigationBar
            )
            .toolbarColorScheme(theme.scheme, for: .navigationBar)
    }
}

// MARK: - Themed section

/// Drop-in replacement for `Section` on themed screens: rows take the surface
/// colour, header and footer take the background's text colour.
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

// MARK: - Text roles

extension View {
    /// Full-strength text on custom backgrounds, system secondary otherwise.
    func themedSecondary() -> some View { modifier(ThemedTextModifier(secondary: true)) }
    func themedText() -> some View { modifier(ThemedTextModifier(secondary: false)) }

    /// Error / success / warning. System colours on the default look; on a
    /// custom background the text colour (pair it with an icon — see `StatusText`).
    func themedStatus(_ kind: ThemedStatus) -> some View { modifier(ThemedStatusModifier(kind: kind)) }

    /// A text field's background, matched to the theme.
    func themedField(cornerRadius: CGFloat = 10) -> some View { modifier(ThemedFieldModifier(cornerRadius: cornerRadius)) }
}

enum ThemedStatus {
    case error, success, warning

    var systemColor: Color {
        switch self {
        case .error: return .red
        case .success: return .green
        case .warning: return .orange
        }
    }

    var symbol: String {
        switch self {
        case .error: return "exclamationmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

private struct ThemedTextModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    let secondary: Bool

    func body(content: Content) -> some View {
        content.foregroundStyle(secondary ? theme.secondaryText : theme.text)
    }
}

private struct ThemedStatusModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    let kind: ThemedStatus

    func body(content: Content) -> some View {
        content.foregroundStyle(theme.isCustom ? theme.text : kind.systemColor)
    }
}

private struct ThemedFieldModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(theme.fieldFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .foregroundStyle(theme.text)
    }
}

/// A message with its status icon. On custom backgrounds the icon carries the
/// meaning, because coloured text is unreadable on most coloured rows.
struct StatusText: View {
    @Environment(\.appTheme) private var theme

    let text: String
    let kind: ThemedStatus

    init(_ text: String, _ kind: ThemedStatus) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if theme.isCustom {
                Image(systemName: kind.symbol)
            }
            Text(text)
        }
        .font(.footnote.weight(theme.isCustom ? .semibold : .regular))
        .themedStatus(kind)
    }
}

// MARK: - Empty state

/// Replaces `ContentUnavailableView`, whose description is always the system's
/// grey and ignores the theme.
struct ThemedEmptyState: View {
    enum Placement {
        /// On a row or bar.
        case surface
        /// Straight on the background.
        case background
    }

    @Environment(\.appTheme) private var theme

    let title: LocalizedStringKey
    let systemImage: String
    var description: LocalizedStringKey? = nil
    var placement: Placement = .surface

    private var primary: Color {
        guard theme.isCustom else { return .primary }
        return placement == .surface ? theme.surfaceText : theme.backgroundText
    }

    private var secondary: Color {
        theme.isCustom ? primary : .secondary
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(secondary)
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(primary)
            if let description {
                Text(description)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons

/// Pill buttons that stay readable on any background.
///
/// Replaces `.borderedProminent.tint(Color.brand)`, which painted a blue pill on
/// blue rows — the invisible "Invite", "Cancel" and "Accept" buttons.
struct ThemedButtonStyle: ButtonStyle {
    enum Kind { case prominent, bordered }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        ThemedButtonBody(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == ThemedButtonStyle {
    static var themedProminent: ThemedButtonStyle { ThemedButtonStyle(kind: .prominent) }
    static var themedBordered: ThemedButtonStyle { ThemedButtonStyle(kind: .bordered) }
}

private struct ThemedButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: ThemedButtonStyle.Kind

    @Environment(\.appTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    private var foreground: Color {
        switch kind {
        case .prominent:
            return theme.accentText
        case .bordered:
            if configuration.role == .destructive && !theme.isCustom { return .red }
            return theme.tint
        }
    }

    var body: some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 34)
            .background { pill }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }

    @ViewBuilder
    private var pill: some View {
        switch kind {
        case .prominent:
            Capsule().fill(theme.accentFill)
        case .bordered:
            if theme.isCustom {
                Capsule().strokeBorder(theme.tint, lineWidth: 1.5)
            } else {
                Capsule().fill(Color.brand.opacity(0.15))
            }
        }
    }
}

/// A row-level button. Destructive ones keep the system red on the default look;
/// on a custom background they use the text colour with an icon and heavier weight.
struct ThemedRowButton: View {
    @Environment(\.appTheme) private var theme

    let title: LocalizedStringKey
    var systemImage: String? = nil
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        if isDestructive && !theme.isCustom {
            Button(role: .destructive, action: action) { label }
        } else if isDestructive {
            Button(action: action) {
                label
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Button(action: action) { label }
        }
    }

    @ViewBuilder
    private var label: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else if isDestructive && theme.isCustom {
            Label(title, systemImage: "exclamationmark.triangle.fill")
        } else {
            Text(title)
        }
    }
}

// MARK: - Sheets

/// A `NavigationStack` for sheets and other presented screens.
///
/// FIX (Done / Clear done / Cancel stayed blue): navigation-bar buttons take their
/// tint from the environment **outside** the stack, not from modifiers applied to
/// the content inside it. `.appScreenStyle()` only reaches the content, so a sheet
/// shown from a screen that had its own tint (the chat's blue) kept that tint on its
/// bar buttons. This sets the tint on the stack itself, where the bar reads it.
struct ThemedNavigationStack<Content: View>: View {
    @EnvironmentObject private var container: AppContainer
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let theme = container.appearanceStore.appTheme
        NavigationStack { content }
            .tint(theme.tint)
            .environment(\.appTheme, theme)
    }
}

// MARK: - Text fields

/// A text field whose placeholder follows the theme.
///
/// A plain `TextField`'s placeholder ignores `foregroundStyle` and is always system
/// grey — "you@example.com" was unreadable on a coloured row. The theme is read
/// *inside* this view, so it sees the theme set by `.appScreenStyle()` on the
/// screen that contains it.
struct ThemedTextField: View {
    @Environment(\.appTheme) private var theme

    private let title: String
    @Binding private var text: String
    private let axis: Axis

    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.title = title
        self._text = text
        self.axis = axis
    }

    var body: some View {
        TextField("", text: $text, prompt: theme.prompt(title), axis: axis)
            .foregroundStyle(theme.text)
            .accessibilityLabel(title)
    }
}

struct ThemedSecureField: View {
    @Environment(\.appTheme) private var theme

    private let title: String
    @Binding private var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        SecureField("", text: $text, prompt: theme.prompt(title))
            .foregroundStyle(theme.text)
            .accessibilityLabel(title)
    }
}

// MARK: - Time picker

/// The alarm's time wheel.
///
/// SwiftUI's `.wheel` `DatePicker` is a UIKit control that ignores both
/// `foregroundStyle` and the SwiftUI colour scheme, so its digits stayed black on a
/// dark row. Wrapping `UIDatePicker` lets the interface style be set explicitly.
struct ThemedTimePicker: UIViewRepresentable {
    @Binding var date: Date
    @Environment(\.appTheme) private var theme

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .wheels
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        picker.overrideUserInterfaceStyle = switch theme.scheme {
        case .dark: .dark
        case .light: .light
        default: .unspecified
        }
        if abs(picker.date.timeIntervalSince(date)) > 0.5 {
            picker.setDate(date, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    final class Coordinator: NSObject {
        let date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }

        @objc func changed(_ picker: UIDatePicker) {
            date.wrappedValue = picker.date
        }
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

/// `LabeledContent` values are grey by default, which drops below readable
/// contrast on a coloured row. On custom backgrounds the value uses the full
/// text colour and is set apart by weight.
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
