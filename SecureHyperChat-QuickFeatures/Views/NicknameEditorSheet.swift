import SwiftUI

/// #2: a private name for a contact, on this phone only.
///
/// Never sent to anyone and never used to look a person up — only for display.
/// Safe to show instead of the username because *you* chose it (unlike a name
/// the other person picks, see S1).
struct NicknameEditorSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let peerId: String
    let username: String
    let current: String?
    var onSaved: () -> Void = {}

    @State private var text = ""
    @State private var errorMessage: String?

    static let maxLength = 40

    var body: some View {
        NavigationStack {
            Form {
                ThemedSection {
                    TextField("Nickname", text: $text)
                        .textInputAutocapitalization(.words)
                        .onChange(of: text) { _, value in
                            if value.count > Self.maxLength { text = String(value.prefix(Self.maxLength)) }
                        }
                } footer: {
                    Text("Shown instead of @\(username) on this phone only. \(username) never sees it.")
                }

                if current != nil {
                    ThemedSection {
                        ThemedRowButton(title: "Remove nickname", isDestructive: true) {
                            save(nil)
                        }
                    }
                }

                if let errorMessage {
                    ThemedSection { StatusText(errorMessage, .error) }
                }
            }
            .navigationTitle("Nickname")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(text) }
                }
            }
            .appScreenStyle()
            .onAppear { text = current ?? "" }
        }
        .presentationDetents([.medium])
    }

    private func save(_ value: String?) {
        guard let me = container.authService.currentUserId else { return }
        // One line, no control or bidi characters (same cleaning as S1).
        let clean = SafeText.line(value, maxLength: Self.maxLength)
        do {
            try container.userRepository.setNickname(ownerUserId: me, userId: peerId, nickname: clean)
            onSaved()
            dismiss()
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
