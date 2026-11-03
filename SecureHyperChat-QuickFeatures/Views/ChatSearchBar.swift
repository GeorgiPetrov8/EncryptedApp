import SwiftUI

/// #6: the in-chat search field, shown under the header notch.
/// (The chat hides the navigation bar, so `.searchable` wouldn't appear.)
struct ChatSearchBar: View {
    @ObservedObject var model: ChatSearchModel
    let chrome: ChromeStyle
    let onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            TextField("Search in chat", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { model.older() }

            if model.isIndexing {
                ProgressView().controlSize(.small)
            } else if !model.statusText.isEmpty {
                Text(model.statusText)
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
            }

            Button { model.older() } label: { Image(systemName: "chevron.up") }
                .disabled(model.matches.isEmpty || model.currentIndex >= model.matches.count - 1)
                .accessibilityLabel("Older match")
            Button { model.newer() } label: { Image(systemName: "chevron.down") }
                .disabled(model.matches.isEmpty || model.currentIndex == 0)
                .accessibilityLabel("Newer match")
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .notchStyle(chrome, cornerRadius: 18)
        .onAppear { focused = true }
    }
}
