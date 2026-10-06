import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var viewModel: ConversationListViewModel
    @State private var showNewInvitation = false
    @State private var navigateToConversation: Conversation?

    init(container: AppContainer) {
        _viewModel = StateObject(
            wrappedValue: ConversationListViewModel(
                conversationRepository: container.conversationRepository,
                messageRepository: container.messageRepository,
                userRepository: container.userRepository,
                messagingService: container.messagingService,
                invitationService: container.invitationService,
                authService: container.authService
            )
        )
    }

    private var listAppearance: ChatAppearance { container.appearanceStore.listAppearance }
    private var chrome: ChromeStyle { container.appearanceStore.chrome(for: listAppearance) }
    private var barTint: Color { container.appearanceStore.barTint }

    var body: some View {
        NavigationStack {
            list
                // FIX: a little space between the bar and the first chat —
                // they used to touch.
                .contentMargins(.top, 12, for: .scrollContent)
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
                .refreshable {
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
        // Back buttons on every pushed screen use the bar colour.
        .tint(barTint)
        .fullScreenCover(isPresented: isCallPresented) {
            CallView()
                .environmentObject(container)
        }
    }

    private var isCallPresented: Binding<Bool> {
        Binding(
            get: { container.callService.phase != .idle },
            set: { _ in }
        )
    }

    // MARK: List

    private var list: some View {
        List {
            if viewModel.summaries.isEmpty {
                ContentUnavailableView(
                    "No conversations yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Tap the compose button to invite someone to an encrypted chat.")
                )
                .foregroundStyle(chrome.fill == nil ? Color.primary : listAppearance.foregroundColor)
                .listRowBackground(Color.clear)
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
                        chrome: chrome
                    )
                }
                .listRowBackground(rowBackground)
                .listRowSeparator(chrome.fill == nil ? .automatic : .hidden)
            }
        }
        .listRowSpacing(chrome.fill == nil ? 0 : 8)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if let fill = chrome.fill {
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
    //
    // Every icon gets an explicit colour — see `AppScreenStyle` for why.

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
                isListening: container.messagingService.isListening,
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
    let chrome: ChromeStyle

    private var primary: Color { chrome.fill == nil ? .primary : chrome.foreground }
    private var secondary: Color { chrome.fill == nil ? .secondary : chrome.foreground }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(
                userId: summary.peerId,
                displayName: summary.otherUsername,
                imageData: avatar,
                size: 48,
                isOnline: isOnline
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(summary.otherUsername)
                        .font(.headline)
                        .foregroundStyle(primary)
                    if summary.isVerified {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption2)
                            .foregroundStyle(chrome.fill == nil ? Color.green : chrome.foreground)
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
        .padding(.vertical, chrome.fill == nil ? 0 : 4)
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
                Text("Not connected").font(.caption2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
