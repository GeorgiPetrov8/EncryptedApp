import SwiftUI
import UIKit

/// Full emoji picker for reactions.
///
/// Two ways to pick:
///   - the built-in grid (every single-character emoji, searchable by its English
///     Unicode name: "heart", "fire", "cat"…);
///   - "Type any emoji" — opens the system emoji keyboard, which also covers flags,
///     skin tones and combined emoji that the grid doesn't list.
///
/// FIX: it was a plain system sheet (hard-coded `.tint(Color.brand)`, grey
/// `.secondary` headings, system-grey fields). It now follows the app theme, so it
/// needs the container in the environment — `ChatView` provides it.
struct EmojiPickerView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let onPick: (String) -> Void

    @State private var query = ""
    @State private var recent: [String] = EmojiRecents.load()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    private var theme: AppTheme { container.appearanceStore.appTheme }

    var body: some View {
        ThemedNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    searchField

                    EmojiKeyboardField(placeholderColor: UIColor(theme.placeholder)) { emoji in pick(emoji) }
                        .frame(height: 20)
                        .themedField()

                    if query.isEmpty {
                        if !recent.isEmpty {
                            section("Recent", items: recent)
                        }
                        ForEach(EmojiCatalog.categories) { category in
                            section(category.title, items: category.items.map(\.emoji))
                        }
                    } else {
                        let matches = EmojiCatalog.search(query)
                        if matches.isEmpty {
                            Text("No emoji match “\(query)”. Try English words, or type one with the keyboard above.")
                                .font(.footnote)
                                .foregroundStyle(theme.onBackground)
                        } else {
                            section("Results", items: matches.map(\.emoji))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .appScreenStyle()
        }
        .presentationDetents([.medium, .large])
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            ThemedTextField("Search emoji", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
            }
        }
        .themedField()
    }

    private func section(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(theme.onBackground)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(items, id: \.self) { emoji in
                    Button {
                        pick(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 30))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pick(_ emoji: String) {
        guard ReactionPayload.isValidEmoji(emoji) else { return }
        EmojiRecents.add(emoji)
        onPick(emoji)
        dismiss()
    }
}

// MARK: - Catalog

enum EmojiCatalog {
    struct Item: Identifiable {
        let emoji: String
        let name: String
        var id: String { emoji }
    }

    struct Category: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    /// Built once from Unicode itself, so it includes every emoji the system knows
    /// about in these blocks — no hand-maintained list to go stale.
    static let categories: [Category] = [
        build("Smileys", [0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A, 0x1FAE0...0x1FAEF]),
        build("People & body", [0x1F440...0x1F4AA, 0x1F930...0x1F94F, 0x1F9B0...0x1F9DF, 0x1FAC0...0x1FACF, 0x1FAF0...0x1FAFF]),
        build("Animals, nature & food", [0x1F300...0x1F37F, 0x1F400...0x1F43F, 0x1F950...0x1F96F, 0x1F980...0x1F9AF, 0x1F9E0...0x1F9FF, 0x1FAB0...0x1FABF, 0x1FAD0...0x1FADF]),
        build("Activities & objects", [0x1F380...0x1F3FF, 0x1F4AB...0x1F5FF, 0x1FA70...0x1FAAF]),
        build("Travel & places", [0x1F680...0x1F6FF]),
        build("Symbols", [0x2600...0x27BF, 0x2B00...0x2BFF, 0x1F900...0x1F90F]),
    ]

    private static let all: [Item] = categories.flatMap(\.items)

    static func search(_ query: String) -> [Item] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return all.filter { item in words.allSatisfy { item.name.contains($0) } }
    }

    private static func build(_ title: String, _ ranges: [ClosedRange<UInt32>]) -> Category {
        var seen = Set<String>()
        var items: [Item] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value) else { continue }
                // Skin-tone modifiers aren't emoji on their own.
                if (0x1F3FB...0x1F3FF).contains(value) { continue }
                let props = scalar.properties
                let emoji: String
                if props.isEmojiPresentation {
                    emoji = String(scalar)
                } else if props.isEmoji {
                    // Text-style symbols (☀, ✔) need VS16 to render as emoji.
                    emoji = String(scalar) + "\u{FE0F}"
                } else {
                    continue
                }
                guard seen.insert(emoji).inserted, ReactionPayload.isValidEmoji(emoji) else { continue }
                items.append(Item(emoji: emoji, name: (props.name ?? "").lowercased()))
            }
        }
        return Category(title: title, items: items)
    }
}

enum EmojiRecents {
    private static let key = "reactions.recent"
    private static let limit = 16

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ emoji: String) {
        var list = load().filter { $0 != emoji }
        list.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }
}

// MARK: - Emoji keyboard

/// A text field that opens straight onto the emoji keyboard and reports the first
/// emoji typed.
struct EmojiKeyboardField: UIViewRepresentable {
    var placeholderColor: UIColor? = nil
    let onEmoji: (String) -> Void

    func makeUIView(context: Context) -> EmojiOnlyTextField {
        let field = EmojiOnlyTextField()
        field.attributedPlaceholder = NSAttributedString(
            string: "Type any emoji ⌨︎",
            attributes: [.foregroundColor: placeholderColor ?? UIColor.placeholderText]
        )
        field.font = .preferredFont(forTextStyle: .body)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ uiView: EmojiOnlyTextField, context: Context) {
        uiView.attributedPlaceholder = NSAttributedString(
            string: "Type any emoji ⌨︎",
            attributes: [.foregroundColor: placeholderColor ?? UIColor.placeholderText]
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(onEmoji: onEmoji) }

    final class Coordinator: NSObject {
        let onEmoji: (String) -> Void
        init(onEmoji: @escaping (String) -> Void) { self.onEmoji = onEmoji }

        @objc func changed(_ field: UITextField) {
            guard let last = field.text?.last else { return }
            let emoji = String(last)
            field.text = ""
            if ReactionPayload.isValidEmoji(emoji) { onEmoji(emoji) }
        }
    }
}

final class EmojiOnlyTextField: UITextField {
    /// Asks iOS for the emoji keyboard. Works when the Emoji keyboard is enabled (it
    /// is by default); otherwise the normal keyboard appears and the 🌐 key
    /// switches to emoji.
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }

    override var textInputContextIdentifier: String? { "" }
}
