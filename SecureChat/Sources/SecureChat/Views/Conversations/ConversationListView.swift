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
                    ContentUnavailableView(
                        "No conversations yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Tap + to start an encrypted conversation.")
                    )
                }
                ForEach(viewModel.summaries) { summary in
                    Button {
                        navigateToConversation = summary.conversation
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.otherUsername)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(summary.lastMessagePreview)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
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
            .onAppear { viewModel.reload() }
        }
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
