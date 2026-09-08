import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var viewModel: ConversationListViewModel
    @State private var showNewConversation = false
    @State private var navigateToConversation: Conversation?

    init(container: AppContainer) {
        _viewModel = StateObject(
            wrappedValue: ConversationListViewModel(
                conversationRepository: container.conversationRepository,
                messageRepository: container.messageRepository,
                userRepository: container.userRepository,
                messagingService: container.messagingService,
                authService: container.authService
            )
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.summaries.isEmpty {
                    // NOTE (Bug #19): `ContentUnavailableView` is iOS 17+, which is
                    // now the deployment target — see project.yml.
                    ContentUnavailableView(
                        "No conversations yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Tap the compose button to start an encrypted conversation.")
                    )
                }
                ForEach(viewModel.summaries) { summary in
                    Button {
                        navigateToConversation = summary.conversation
                    } label: {
                        ConversationRow(summary: summary)
                    }
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                // FIX (Bug #25): visible connection state.
                //
                // When the listener failed to start there was no way to tell from the
                // UI — the app looked normal and simply never received anything.
                ToolbarItem(placement: .principal) {
                    ConnectionIndicator(
                        isListening: container.messagingService.isListening,
                        isSyncing: container.messagingService.isSyncing
                    )
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showNewConversation = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .navigationDestination(item: $navigateToConversation) { conversation in
                ChatView(container: container, conversation: conversation)
            }
            .sheet(isPresented: $showNewConversation) {
                NewConversationSheet(viewModel: viewModel, onStarted: { conversation in
                    showNewConversation = false
                    navigateToConversation = conversation
                })
            }
            .refreshable {
                // FIX (Bug #12): manual recovery path if the listener is wedged.
                if let userId = container.authService.currentUserId {
                    await container.messagingService.backfillPendingEnvelopes(myUserId: userId)
                }
                viewModel.reload()
            }
            .onAppear { viewModel.reload() }
        }
    }
}

private struct ConversationRow: View {
    let summary: ConversationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary.otherUsername)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if summary.isVerified {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Identity verified")
                }
                if summary.hasIdentityWarning {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Security keys changed")
                }
                Spacer()
                if let date = summary.lastActivityAt {
                    Text(date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(summary.lastMessagePreview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ConnectionIndicator: View {
    let isListening: Bool
    let isSyncing: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isSyncing {
                ProgressView().controlSize(.mini)
                Text("Syncing…").font(.caption2)
            } else if !isListening {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Not connected").font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct NewConversationSheet: View {
    @ObservedObject var viewModel: ConversationListViewModel
    let onStarted: (Conversation) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Start a new encrypted conversation") {
                    TextField("Their username", text: $viewModel.newConversationUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("New Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if let conversation = await viewModel.startConversation() {
                                onStarted(conversation)
                            }
                        }
                    } label: {
                        if viewModel.isStartingConversation {
                            ProgressView()
                        } else {
                            Text("Start")
                        }
                    }
                }
            }
        }
    }
}
