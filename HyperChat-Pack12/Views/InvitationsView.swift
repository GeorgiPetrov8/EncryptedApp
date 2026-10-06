import SwiftUI

/// Pending contact requests.
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
        .appScreenStyle()
        .onAppear { service.reloadPending() }
    }
}

private struct InvitationRow: View {
    @EnvironmentObject private var container: AppContainer
    let conversation: Conversation
    let onAccept: () -> Void
    let onDecline: () -> Void

    @State private var contact: User?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(
                    userId: peerId ?? "",
                    displayName: displayName,
                    imageData: peerId.flatMap { container.profileService.avatarData(for: $0) },
                    size: 44
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
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
                Button {
                    isWorking = true
                    onAccept()
                } label: {
                    Text("Accept").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)

                Button(role: .destructive) {
                    isWorking = true
                    onDecline()
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(isWorking)

            Text("They can't message or call you until you accept.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .onAppear(perform: loadContact)
    }

    private var peerId: String? {
        guard let myUserId = container.authService.currentUserId else { return nil }
        return conversation.otherParticipant(myUserId: myUserId)
    }

    private var displayName: String {
        if let contact { return contact.shownName }
        return String((peerId ?? "Unknown").prefix(8))
    }

    private func loadContact() {
        guard let myUserId = container.authService.currentUserId, let peerId else { return }
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

    let onInvited: (Conversation) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Who")
                } footer: {
                    Text("They'll get an invitation. Once they accept, your chat opens for both of you — anything you write before that is sent then.")
                }

                Section {
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
