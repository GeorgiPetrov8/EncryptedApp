import SwiftUI

/// Pending contact requests.
struct InvitationsView: View {
    @EnvironmentObject private var container: AppContainer

    private var service: InvitationService { container.invitationService }

    var body: some View {
        List {
            if service.pendingIncoming.isEmpty {
                ThemedEmptyState(
                    title: "No invitations",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: "When someone invites you to chat, it'll appear here.",
                    placement: .background
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(service.pendingIncoming) { conversation in
                    // One section per invitation, so each is its own card and every
                    // row takes the theme's surface.
                    ThemedSection {
                        InvitationRow(
                            conversation: conversation,
                            onAccept: { Task { await service.accept(conversation) } },
                            onDecline: { Task { await service.decline(conversation) } }
                        )
                    }
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
    @Environment(\.appTheme) private var theme

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
                        .themedText()
                    if let sentAt = conversation.inviteSentAt {
                        (Text(sentAt, style: .relative) + Text(" ago"))
                            .font(.caption)
                            .themedSecondary()
                    }
                }
            }

            if let note = conversation.inviteNote, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themedField()
            }

            // FIX: `.borderedProminent.tint(Color.brand)` was a blue pill on a blue
            // row. These two keep their contrast on any background.
            HStack(spacing: 10) {
                Button {
                    isWorking = true
                    onAccept()
                } label: {
                    Text("Accept").frame(maxWidth: .infinity)
                }
                .buttonStyle(.themedProminent)

                Button(role: .destructive) {
                    isWorking = true
                    onDecline()
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.themedBordered)
            }
            .disabled(isWorking)

            Text("They can't message or call you until you accept.")
                .font(.caption2)
                .themedSecondary()
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

/// "New Chat": invite someone by username.
struct NewInvitationView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var note = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    let onInvited: (Conversation) -> Void

    var body: some View {
        ThemedNavigationStack {
            Form {
                ThemedSection {
                    ThemedTextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Who")
                } footer: {
                    Text("They'll get an invitation. Once they accept, your chat opens for both of you — anything you write before that is sent then.")
                }

                ThemedSection {
                    ThemedTextField("Optional note", text: $note, axis: .vertical)
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
                    ThemedSection { StatusText(errorMessage, .error) }
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
