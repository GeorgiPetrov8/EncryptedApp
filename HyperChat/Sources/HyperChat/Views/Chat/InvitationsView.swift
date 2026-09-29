import SwiftUI

/// Pending contact requests (feature #6).
struct InvitationsView: View {
    @EnvironmentObject private var container: AppContainer

    private var service: InvitationService { container.invitationService }

    var body: some View {
        List {
            if service.pendingIncoming.isEmpty {
                ContentUnavailableView(
                    "No invitations",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("When someone invites you to chat, it'll appear here.")
                )
            } else {
                ForEach(service.pendingIncoming) { conversation in
                    InvitationRow(
                        conversation: conversation,
                        onAccept: { Task { await service.accept(conversation) } },
                        onDecline: { Task { await service.decline(conversation) } }
                    )
                }
            }
        }
        .navigationTitle("Invitations")
        .onAppear { service.reloadPending() }
    }
}

private struct InvitationRow: View {
    @EnvironmentObject private var container: AppContainer
    let conversation: Conversation
    let onAccept: () -> Void
    let onDecline: () -> Void

    @State private var contact: User?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(
                    userId: contact?.id ?? "",
                    displayName: displayName,
                    imageData: nil,
                    size: 44
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName).font(.headline)
                    if let sentAt = conversation.inviteSentAt {
                        Text(sentAt, style: .relative) + Text(" ago")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let note = conversation.inviteNote, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 10) {
                Button(action: onAccept) {
                    Text("Accept").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onDecline) {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            // Stated plainly, because the security value of the invite gate
            // depends on the user understanding that accepting is what opens
            // the channel — not something that already happened.
            Text("They can't message you until you accept.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .onAppear(perform: loadContact)
    }

    private var displayName: String {
        if let contact, !contact.username.isEmpty { return contact.username }
        guard let myUserId = container.authService.currentUserId,
              let peerId = conversation.otherParticipant(myUserId: myUserId) else { return "Unknown" }
        return String(peerId.prefix(8))
    }

    private func loadContact() {
        guard let myUserId = container.authService.currentUserId,
              let peerId = conversation.otherParticipant(myUserId: myUserId) else { return }
        contact = try? container.userRepository.fetch(ownerUserId: myUserId, id: peerId)
    }
}

/// Composes a new invitation.
struct NewInvitationView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var note = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    /// Handed the created conversation so the caller can navigate straight
    /// into it — the chat exists immediately, which is the point of the
    /// feature.
    let onInvited: (Conversation) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Who") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("Optional note", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .onChange(of: note) { _, newValue in
                            // Enforced here as well as in the payload, so the
                            // limit is visible rather than silently truncating
                            // on send.
                            if newValue.count > InviteLimits.maxNoteLength {
                                note = String(newValue.prefix(InviteLimits.maxNoteLength))
                            }
                        }
                } header: {
                    Text("Note")
                } footer: {
                    Text("\(note.count)/\(InviteLimits.maxNoteLength) — a short note helps them recognise you. They'll see this before deciding.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
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
                        if isSending { ProgressView() } else { Text("Invite") }
                    }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
                }
            }
        }
    }

    private func send() {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let conversation = try await container.invitationService.invite(
                    username: username.trimmingCharacters(in: .whitespaces),
                    note: note.isEmpty ? nil : note
                )
                onInvited(conversation)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
