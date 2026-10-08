import SwiftUI

/// "New Chat": invite someone by username.
///
/// FIX: uses `ThemedSection`, so rows take the notch colour and the
/// header/footer are readable on the background. The manual
/// `.foregroundStyle(barTint)` calls are gone — toolbar buttons ignore
/// `foregroundStyle`; they follow the `tint` that `.appScreenStyle()` sets.
struct NewInvitationView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var note = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    let onInvited: (Conversation) -> Void

    var body: some View {
        NavigationStack {
            Form {
                ThemedSection {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Who")
                } footer: {
                    Text("They'll get an invitation. Once they accept, your chat opens for both of you — anything you write before that is sent then.")
                }

                ThemedSection {
                    TextField("Optional note", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .onChange(of: note) { _, newValue in
                            if newValue.count > InviteLimits.maxNoteLength {
                                note = String(newValue.prefix(InviteLimits.maxNoteLength))
                            }
                        }
                } header: {
                    Text("Note")
                } footer: {
                    Text("\(note.count)/\(InviteLimits.maxNoteLength) — helps them recognise you.")
                }

                if let errorMessage {
                    ThemedSection {
                        Text(errorMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: send) {
                        if isSending { ProgressView() } else { Text("Invite").bold() }
                    }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
                }
            }
            .appScreenStyle()
        }
    }

    private func send() {
        isSending = true
        errorMessage = nil
        Task {
            defer { isSending = false }
            do {
                let conversation = try await container.invitationService.invite(
                    username: username.trimmingCharacters(in: .whitespaces),
                    note: note.isEmpty ? nil : note
                )
                onInvited(conversation)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
