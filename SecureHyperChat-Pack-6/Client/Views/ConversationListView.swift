import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var viewModel: ConversationListViewModel
    @ObservedObject private var connection: ConnectionMonitor
    @State private var showNewInvitation = false
    @State private var navigateToConversation: Conversation?
    @State private var pendingDelete: ConversationSummary?

    init(container: AppContainer) {
        _connection = ObservedObject(wrappedValue: container.connectionMonitor)
        _viewModel = StateObject(
            wrappedValue: ConversationListViewModel(
                conversationRepository: container.conversationRepository,
                messageRepository: container.messageRepository,
                userRepository: container.userRepository,
                messagingService: container.messagingService,
                invitationService: container.invitationService,
                authService: container.authService,
                deletion: container.conversationDeletion
            )
        )
    }

    private var theme: AppTheme { container.appearanceStore.appTheme }
    private var barTint: Color { theme.tint }

    var body: some View {
        NavigationStack {
            list
                .appScreenStyle(adaptsContent: false)
                .navigationTitle("Chats")
                .toolbar { toolbarContent }
                .navigationDestination(item: $navigateToConversation) { conversation in
                    ChatView(container: container, conversation: conversation)
                }
                .sheet(isPresented: $showNewInvitation) {
                    NewInvitationView { conversation in
                        showNewInvitation = false
                        viewModel.reload()
                        navigateToConversation = conversation
                    }
                    .environmentObject(container)
                }
                .confirmationDialog(
                    "Delete this chat?",
                    isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                    titleVisibility: .visible,
                    presenting: pendingDelete
                ) { summary in
                    Button("Delete chat", role: .destructive) { viewModel.delete(summary) }
                    Button("Delete and block", role: .destructive) {
                        container.messagingService.block(userId: summary.peerId)
                        viewModel.delete(summary)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { summary in
                    Text("All messages, photos and files with \(summary.otherUsername) are removed from this phone. \(summary.otherUsername) keeps their copy and isn't told.")
                }
                .refreshable {
                    connection.reconnect()
                    if let userId = container.authService.currentUserId {
                        await container.messagingService.backfillPendingEnvelopes(myUserId: userId)
                    }
                    viewModel.reload()
                    container.invitationService.reloadPending()
                }
                .onAppear {
                    viewModel.reload()
                    container.invitationService.reloadPending()
                    MediaExporter.purge()
                }
                .task { await container.invitationService.requestNotificationPermission() }
        }
        .tint(barTint)
        .fullScreenCover(isPresented: isCallPresented) {
            CallView()
                .environmentObject(container)
        }
    }

    private var isCallPresented: Binding<Bool> {
        Binding(get: { container.callService.phase != .idle }, set: { _ in })
    }

    // MARK: List

    private var list: some View {
        List {
            if viewModel.summaries.isEmpty {
                ThemedEmptyState(
                    title: "No conversations yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: "Tap the compose button to invite someone to an encrypted chat.",
                    placement: .background
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(viewModel.summaries) { summary in
                Button {
                    navigateToConversation = summary.conversation
                } label: {
                    ConversationRow(
                        summary: summary,
                        avatar: avatar(for: summary.peerId),
                        isOnline: summary.relationshipState == .accepted
                            && container.presenceService.isOnline(summary.peerId),
                        theme: theme
                    )
                }
                .listRowBackground(rowBackground)
                .listRowSeparator(theme.isCustom ? .hidden : .automatic)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = summary
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        pendingDelete = summary
                    } label: {
                        Label("Delete chat", systemImage: "trash")
                    }
                }
            }
        }
        .listRowSpacing(theme.isCustom ? 8 : 0)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if let fill = theme.surface {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill)
        } else {
            Color(.systemBackground)
        }
    }

    private func avatar(for peerId: String) -> Data? {
        _ = container.profileService.version
        return container.profileService.avatarData(for: peerId)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(barTint)
            }
            .accessibilityLabel("Settings")
        }

        ToolbarItem(placement: .principal) {
            ConnectionIndicator(
                isConnected: connection.isConnected,
                isOnline: connection.isOnline,
                isSyncing: container.messagingService.isSyncing
            )
            .foregroundStyle(barTint)
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            NavigationLink {
                InvitationsView()
            } label: {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(barTint)
                    .overlay(alignment: .topTrailing) { invitationBadge }
            }
            .accessibilityLabel("Invitations, \(container.invitationService.pendingCount) pending")

            Button {
                showNewInvitation = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(barTint)
            }
            .accessibilityLabel("New chat")
        }
    }

    @ViewBuilder
    private var invitationBadge: some View {
        let count = container.invitationService.pendingCount
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(Circle().fill(Color.red))
                .offset(x: 8, y: -8)
        }
    }
}

private struct ConversationRow: View {
    let summary: ConversationSummary
    let avatar: Data?
    let isOnline: Bool
    let theme: AppTheme

    private var primary: Color { theme.text }
    private var secondary: Color { theme.secondaryText }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(
                userId: summary.peerId,
                displayName: summary.otherUsername,
                imageData: avatar,
                size: 48,
                isOnline: isOnline,
                ringColor: theme.surface
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(summary.otherUsername)
                        .font(.headline)
                        .foregroundStyle(primary)
                    if summary.isVerified {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.isCustom ? theme.surfaceText : Color.green)
                            .accessibilityLabel("Identity verified")
                    }
                    if summary.hasIdentityWarning {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.isCustom ? theme.surfaceText : Color.red)
                            .accessibilityLabel("Security keys changed")
                    }
                    Spacer()
                    if let date = summary.lastActivityAt {
                        Text(date, style: .time)
                            .font(.caption2)
                            .foregroundStyle(secondary)
                    }
                }

                HStack(spacing: 4) {
                    stateIcon
                    Text(summary.lastMessagePreview)
                        .font(.subheadline)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, theme.isCustom ? 4 : 0)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch summary.relationshipState {
        case .invitedByMe:
            Image(systemName: "hourglass").font(.caption).foregroundStyle(secondary)
        case .declined:
            Image(systemName: "xmark.circle").font(.caption).foregroundStyle(secondary)
        case .accepted, .invitedByThem:
            EmptyView()
        }
    }
}

/// Shows only when something is wrong — connected is the normal state.
private struct ConnectionIndicator: View {
    let isConnected: Bool
    let isOnline: Bool
    let isSyncing: Bool

    var body: some View {
        HStack(spacing: 6) {
            if !isOnline {
                Image(systemName: "wifi.slash").font(.caption)
                Text("No internet").font(.caption2)
            } else if isSyncing {
                ProgressView().controlSize(.mini)
                Text("Syncing…").font(.caption2)
            } else if !isConnected {
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(.caption2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
