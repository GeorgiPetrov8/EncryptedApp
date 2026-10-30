import SwiftUI
import PhotosUI

struct ChatView: View {
    let container: AppContainer

    @StateObject private var viewModel: ChatViewModel
    @ObservedObject private var appearanceStore: AppearanceStore
    @ObservedObject private var presenceService: PresenceService
    @ObservedObject private var profileService: ProfileService
    @ObservedObject private var gifService: GIFService

    @Environment(\.dismiss) private var dismiss

    @State private var showVerifyIdentity = false
    @State private var showNotePad = false
    @State private var showAppearanceSettings = false
    @State private var showCameraPicker = false
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var showGIFPicker = false
    @State private var reactionTarget: DisplayMessage?

    /// #1: is the last message on screen?
    @State private var isAtBottom = true
    /// Messages that arrived while scrolled up (badge on the button).
    @State private var unseenCount = 0
    /// Loading older pages only after the first positioning (the top is briefly
    /// on screen before the list scrolls).
    @State private var canLoadOlder = false

    private static let bottomId = "chat.bottom"

    init(container: AppContainer, conversation: Conversation) {
        self.container = container
        _appearanceStore = ObservedObject(wrappedValue: container.appearanceStore)
        _presenceService = ObservedObject(wrappedValue: container.presenceService)
        _profileService = ObservedObject(wrappedValue: container.profileService)
        _gifService = ObservedObject(wrappedValue: container.tenorService)
        _viewModel = StateObject(
            wrappedValue: ChatViewModel(
                conversation: conversation,
                messageRepository: container.messageRepository,
                conversationRepository: container.conversationRepository,
                messagingService: container.messagingService,
                authService: container.authService,
                receiptService: container.receiptService,
                invitationService: container.invitationService,
                draftStore: container.draftStore
            )
        )
    }

    // MARK: Body

    var body: some View {
        messageList
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .background { chatBackground }
            .environment(\.chatAppearance, appearance)
            .environment(\.chromeStyle, chrome)
            .environment(\.appTheme, chatTheme)
            .tint(Color.brand)
            .toolbar(.hidden, for: .navigationBar)
            .appNavigationBarStyle(appearanceStore.appTheme)
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $viewModel.selectedPhotoItem,
                matching: .any(of: [.images, .videos])
            )
            .sheet(isPresented: $showVerifyIdentity, onDismiss: { viewModel.reloadPeer() }) {
                verifyIdentitySheet.environmentObject(container)
            }
            .sheet(isPresented: $showNotePad) {
                NotePadView(container: container, conversation: viewModel.conversation)
                    .environmentObject(container)
            }
            .sheet(isPresented: $showAppearanceSettings) {
                AppearanceSettingsView(scope: .conversation(viewModel.conversation.id))
                    .environmentObject(container)
            }
            .sheet(isPresented: $showCameraPicker) {
                CameraPicker(
                    onCaptured: { capture in
                        showCameraPicker = false
                        Task { await viewModel.sendCapturedMedia(capture) }
                    },
                    onCancelled: { showCameraPicker = false }
                )
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPicker(
                    onPicked: { url in
                        showDocumentPicker = false
                        Task { await viewModel.sendDocument(from: url) }
                    },
                    onCancelled: { showDocumentPicker = false }
                )
            }
            .sheet(isPresented: $showGIFPicker) {
                GIFPickerView { gif in
                    Task { await viewModel.sendGIF(gif) }
                }
                .environmentObject(container)
            }
            .sheet(item: $reactionTarget) { message in
                EmojiPickerView { emoji in
                    viewModel.react(to: message, emoji: emoji)
                }
                .environmentObject(container)
            }
            .sheet(item: $viewModel.sharedFile) { file in
                ActivityView(url: file.url) { viewModel.finishedWith(file) }
                    .presentationDetents([.medium, .large])
            }
            .fullScreenCover(item: $viewModel.playingVideo) { file in
                VideoPlayerScreen(url: file.url) { viewModel.finishedWith(file) }
            }
            .onAppear {
                viewModel.reloadConversation()
                viewModel.reloadPeer()
                viewModel.setVisible(true)
                Task { await container.profileService.ensureShared(with: viewModel.conversation) }
            }
            .onDisappear { viewModel.setVisible(false) }
            .onChange(of: viewModel.wasRemoved) { _, removed in
                if removed { dismiss() }
            }
    }

    // MARK: Appearance

    private var appearance: ChatAppearance {
        appearanceStore.appearance(for: viewModel.conversation.id)
    }

    private var chatTheme: AppTheme { appearanceStore.theme(for: appearance) }
    private var chrome: ChromeStyle { chatTheme.chrome }

    private var chatBackground: some View {
        ChatBackgroundView(appearance: appearance) { appearanceStore.imageURL(fileName: $0) }
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(spacing: 6) {
            ChatHeaderNotch(
                peerId: viewModel.peerId,
                name: viewModel.peerUsername,
                alias: viewModel.peerUnverifiedName,
                avatar: peerAvatarData,
                isOnline: isPeerOnline,
                ringColor: chrome.fill,
                isVerified: viewModel.peerIsVerified,
                identityChanged: viewModel.peerIdentityChanged,
                canCall: viewModel.canCall,
                notePadEnabled: viewModel.relationshipState == .accepted,
                notePadBadge: notePadBadgeCount,
                onBack: { dismiss() },
                onCall: startCall,
                onNotePad: { showNotePad = true },
                onVerify: { showVerifyIdentity = true },
                onAppearance: { showAppearanceSettings = true }
            )
            .notchStyle(chrome)

            identityBanner
            invitationBanner
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .environment(\.appTheme, chatTheme)
        .environment(\.chromeStyle, chrome)
    }

    @ViewBuilder
    private var identityBanner: some View {
        if viewModel.peerIdentityChanged {
            IdentityChangedBanner(username: viewModel.peerUsername) { showVerifyIdentity = true }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private var invitationBanner: some View {
        switch viewModel.relationshipState {
        case .accepted:
            EmptyView()
        case .invitedByThem:
            InvitationBanner(
                icon: "person.crop.circle.badge.questionmark",
                title: "\(viewModel.peerUsername) wants to chat with you",
                detail: viewModel.conversation.inviteNote,
                isBusy: viewModel.isUpdatingInvitation
            ) {
                Button("Accept") { Task { await viewModel.acceptInvitation() } }
                    .buttonStyle(.themedProminent)
                Button("Decline", role: .destructive) { Task { await viewModel.declineInvitation() } }
                    .buttonStyle(.themedBordered)
                Button("Block", role: .destructive) { Task { await viewModel.declineInvitation(block: true) } }
                    .buttonStyle(.themedBordered)
            }
            .notchStyle(chrome, cornerRadius: 16)
        case .invitedByMe:
            InvitationBanner(
                icon: "hourglass",
                title: "Waiting for \(viewModel.peerUsername) to accept",
                detail: "You can write now — your messages will be sent as soon as they accept.",
                isBusy: viewModel.isUpdatingInvitation
            ) {
                Button("Resend invitation") { Task { await viewModel.resendInvitation() } }
                    .buttonStyle(.themedBordered)
            }
            .notchStyle(chrome, cornerRadius: 16)
        case .declined:
            InvitationBanner(
                icon: "xmark.circle",
                title: "\(viewModel.peerUsername) declined your invitation",
                detail: nil,
                isBusy: viewModel.isUpdatingInvitation
            ) {
                Button("Invite again") { Task { await viewModel.resendInvitation() } }
                    .buttonStyle(.themedBordered)
            }
            .notchStyle(chrome, cornerRadius: 16)
        }
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if viewModel.hasOlder {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .onAppear {
                                guard canLoadOlder else { return }
                                let anchor = viewModel.messages.first?.id
                                viewModel.loadOlder()
                                if let anchor {
                                    DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            }
                    }

                    ForEach(viewModel.messages) { message in
                        VStack(spacing: 8) {
                            if message.id == viewModel.unreadAnchorId {
                                UnreadDivider(count: viewModel.unreadCount)
                            }
                            MessageBubbleView(
                                message: message,
                                peerIsVerified: viewModel.peerIsVerified,
                                allowGIFAutoload: gifService.isEnabled,
                                canReact: viewModel.canCompose,
                                mediaLoader: { await viewModel.loadMediaData(forMessageId: $0) },
                                onReply: { viewModel.startReply(to: message) },
                                onEdit: { viewModel.startEdit(message) },
                                onDelete: { viewModel.deleteForMe(message) },
                                onQuoteTap: { id in
                                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                                },
                                onReact: { emoji in viewModel.react(to: message, emoji: emoji) },
                                onMoreReactions: { reactionTarget = message },
                                onShare: { await viewModel.shareMedia(messageId: message.id) },
                                onPlayVideo: { await viewModel.playVideo(messageId: message.id) }
                            )
                        }
                        .id(message.id)
                    }

                    // #1: tells whether the end of the chat is on screen.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                        .onAppear {
                            isAtBottom = true
                            unseenCount = 0
                        }
                        .onDisappear { isAtBottom = false }
                }
                .padding(.horizontal)
                .padding(.top, 14)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    ScrollToBottomButton(count: unseenCount, theme: chatTheme) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(Self.bottomId, anchor: .bottom)
                        }
                        unseenCount = 0
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isAtBottom)
            // #9: a new message only pulls you down if you were already at the
            // bottom or you sent it; otherwise it's counted on the button.
            .onChange(of: viewModel.messages.last?.id) { oldId, newId in
                guard let newId, oldId != nil, newId != oldId,
                      let last = viewModel.messages.last else { return }
                if isAtBottom || last.isMine {
                    withAnimation { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                } else {
                    unseenCount += 1
                }
            }
            .onChange(of: viewModel.scrollRequest) { _, request in
                guard let request else { return }
                DispatchQueue.main.async {
                    switch request.target {
                    case .bottom:
                        proxy.scrollTo(Self.bottomId, anchor: .bottom)
                    case .message(let id):
                        proxy.scrollTo(id, anchor: .top)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { canLoadOlder = true }
                }
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 6) {
            noticeBars

            VStack(spacing: 0) {
                composerContext
                MessageInputBar(
                    text: $viewModel.draftText,
                    isSending: viewModel.isSending,
                    isSendingMedia: viewModel.isSendingMedia,
                    disabledReason: viewModel.composeDisabledReason,
                    isEditing: viewModel.editing != nil,
                    focusRequest: viewModel.focusRequest,
                    onSend: { Task { await viewModel.send() } },
                    onCamera: { showCameraPicker = true },
                    onPhotoLibrary: { showPhotoPicker = true },
                    onDocument: { showDocumentPicker = true },
                    onGIF: { showGIFPicker = true },
                    onVoiceFinished: { voiceMessage in
                        Task { await viewModel.sendVoiceMessage(voiceMessage) }
                    }
                )
            }
            .notchStyle(chrome)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .environment(\.appTheme, chatTheme)
        .environment(\.chromeStyle, chrome)
    }

    @ViewBuilder
    private var composerContext: some View {
        if let reply = viewModel.replyingTo {
            ComposerContextBar(
                icon: "arrowshape.turn.up.left.fill",
                title: reply.isMine ? "Replying to yourself" : "Replying to \(viewModel.peerUsername)",
                detail: reply.text,
                onCancel: viewModel.cancelComposerContext
            )
        } else if let editing = viewModel.editing {
            ComposerContextBar(
                icon: "pencil",
                title: "Edit message",
                detail: editing.copyText ?? "",
                onCancel: viewModel.cancelComposerContext
            )
        }
    }

    @ViewBuilder
    private var noticeBars: some View {
        if let receiveError = viewModel.receiveError {
            NoticeBar(
                text: receiveError,
                tint: .orange,
                icon: "exclamationmark.triangle.fill",
                onDismiss: { viewModel.dismissReceiveError() }
            )
            .notchStyle(chrome, cornerRadius: 16)
        }
        if let error = viewModel.errorMessage {
            NoticeBar(
                text: error,
                tint: .red,
                icon: "xmark.octagon.fill",
                onDismiss: { viewModel.dismissSendError() },
                action: retryAction
            )
            .notchStyle(chrome, cornerRadius: 16)
        }
    }

    private var retryAction: NoticeBar.Action? {
        guard viewModel.canRetryLastSend else { return nil }
        return NoticeBar.Action(title: "Retry") {
            Task { await viewModel.retryLastSend() }
        }
    }

    // MARK: Actions & derived values

    private func startCall(video: Bool) {
        Task {
            await container.callService.startCall(in: viewModel.conversation, video: video)
            if case .idle = container.callService.phase,
               let error = container.callService.consumeError() {
                viewModel.errorMessage = error
            }
        }
    }

    private var isPeerOnline: Bool {
        guard let peerId = viewModel.peerId else { return false }
        return presenceService.isOnline(peerId)
    }

    private var peerAvatarData: Data? {
        _ = profileService.version
        guard let peerId = viewModel.peerId else { return nil }
        return profileService.avatarData(for: peerId)
    }

    private var notePadBadgeCount: Int {
        container.notePadService
            .items(for: viewModel.conversation.id)
            .filter { !$0.isDeleted && !$0.isDone }
            .count
    }

    @ViewBuilder
    private var verifyIdentitySheet: some View {
        if let peerId = viewModel.peerId {
            VerifyIdentityView(peerId: peerId, peerUsername: viewModel.peerUsername)
        }
    }
}

// MARK: - Unread line (#4)

private struct UnreadDivider: View {
    @Environment(\.appTheme) private var theme
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(theme.onBackground.opacity(0.5)).frame(height: 1)
            Text(count == 1 ? "1 unread message" : "\(count) unread messages")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.isCustom ? theme.text : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(theme.incomingBubbleFill, in: Capsule())
            Rectangle().fill(theme.onBackground.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scroll to bottom (#1)

private struct ScrollToBottomButton: View {
    let count: Int
    let theme: AppTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.isCustom ? theme.text : Color.primary)
                .frame(width: 42, height: 42)
                .background { background }
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .overlay(alignment: .topLeading) {
                    if count > 0 {
                        Text(count > 99 ? "99+" : "\(count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.brand))
                            .offset(x: -6, y: -6)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(count) new messages, scroll to the latest" : "Scroll to the latest message")
    }

    @ViewBuilder
    private var background: some View {
        if let surface = theme.surface {
            Circle().fill(surface)
        } else {
            Circle().fill(.regularMaterial)
        }
    }
}

// MARK: - Header notch

private struct ChatHeaderNotch: View {
    let peerId: String?
    let name: String
    let alias: String?
    let avatar: Data?
    let isOnline: Bool
    let ringColor: Color?
    let isVerified: Bool
    let identityChanged: Bool
    let canCall: Bool
    let notePadEnabled: Bool
    let notePadBadge: Int
    let onBack: () -> Void
    let onCall: (Bool) -> Void
    let onNotePad: () -> Void
    let onVerify: () -> Void
    let onAppearance: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 28, height: 36)
            }
            .accessibilityLabel("Back")

            AvatarView(userId: peerId ?? name, displayName: name, imageData: avatar, size: 36, isOnline: isOnline, ringColor: ringColor)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name).font(.headline).lineLimit(1)
                    if isVerified {
                        Image(systemName: "checkmark.shield.fill").font(.caption2)
                    }
                }
                if isOnline {
                    Text("online").font(.caption2.weight(.medium))
                } else if let alias {
                    // The name they chose for themselves — unverified (S1).
                    Text("“\(alias)”").font(.caption2).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            Menu {
                Button { onCall(false) } label: { Label("Voice call", systemImage: "phone") }
                Button { onCall(true) } label: { Label("Video call", systemImage: "video") }
            } label: {
                Image(systemName: "phone").font(.title3).frame(width: 32, height: 36)
            }
            .disabled(!canCall)
            .opacity(canCall ? 1 : 0.4)
            .accessibilityLabel("Call")

            Button(action: onNotePad) {
                Image(systemName: "checklist")
                    .font(.title3)
                    .frame(width: 32, height: 36)
                    .overlay(alignment: .topTrailing) {
                        if notePadBadge > 0 {
                            Text("\(notePadBadge)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(Color.red))
                                .offset(x: 6, y: -4)
                        }
                    }
            }
            .disabled(!notePadEnabled)
            .opacity(notePadEnabled ? 1 : 0.4)
            .accessibilityLabel("Shared pad")

            Menu {
                Button(action: onVerify) {
                    Label("Verify security", systemImage: identityChanged ? "exclamationmark.shield.fill" : "shield")
                }
                Button(action: onAppearance) {
                    Label("Chat background", systemImage: "paintbrush")
                }
            } label: {
                Image(systemName: identityChanged ? "exclamationmark.shield.fill" : "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 32, height: 36)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Supporting views

private struct ComposerContextBar: View {
    let icon: String
    let title: String
    let detail: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.footnote)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.bold())
                Text(detail).font(.caption).lineLimit(1)
            }
            Spacer()
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }
}

struct NoticeBar: View {
    struct Action {
        let title: String
        let handler: () -> Void
    }

    let text: String
    let tint: Color
    let icon: String
    let onDismiss: () -> Void
    var action: Action?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.footnote)
            Spacer()
            if let action {
                Button(action.title, action: action.handler).buttonStyle(.themedBordered)
            }
            Button(action: onDismiss) { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 4) }
    }
}

private struct InvitationBanner<Actions: View>: View {
    let icon: String
    let title: String
    let detail: String?
    let isBusy: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline.bold())
            if let detail, !detail.isEmpty {
                Text(detail).font(.footnote)
            }
            HStack(spacing: 10) {
                actions()
                if isBusy { ProgressView() }
            }
            .disabled(isBusy)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IdentityChangedBanner: View {
    let username: String
    let onReview: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("Security keys for \(username) changed").font(.footnote.bold())
                Text("Messaging is paused until you review this.").font(.caption)
            }
            Spacer()
            Button("Review", action: onReview)
                .font(.footnote.bold())
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red)
    }
}

private struct MessageInputBar: View {
    @Binding var text: String

    @StateObject private var voiceRecorder = VoiceRecorder()
    @FocusState private var isFocused: Bool

    let isSending: Bool
    let isSendingMedia: Bool
    let disabledReason: String?
    let isEditing: Bool
    let focusRequest: Int
    let onSend: () -> Void
    let onCamera: () -> Void
    let onPhotoLibrary: () -> Void
    let onDocument: () -> Void
    let onGIF: () -> Void
    let onVoiceFinished: (RecordedVoiceMessage) -> Void

    private var isDisabled: Bool { disabledReason != nil }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var remaining: Int { DraftStore.maxLength - text.count }

    var body: some View {
        VStack(spacing: 0) {
            if isSendingMedia {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Sending attachment…").font(.caption2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }
            controls
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            // #9: a counter only near the limit.
            if remaining < 500 {
                Text("\(max(remaining, 0)) characters left")
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
        }
        .onChange(of: focusRequest) { _, _ in isFocused = true }
        .onChange(of: text) { _, newValue in
            if newValue.count > DraftStore.maxLength {
                text = String(newValue.prefix(DraftStore.maxLength))
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if voiceRecorder.isRecording && voiceRecorder.isLocked {
            LockedRecordingControls(recorder: voiceRecorder, onSend: onVoiceFinished)
        } else {
            HStack(spacing: 8) {
                if voiceRecorder.isRecording {
                    VoiceRecordingBar(recorder: voiceRecorder).frame(maxWidth: .infinity)
                } else {
                    AttachmentMenu(
                        isDisabled: isDisabled || isSendingMedia || isEditing,
                        onCamera: onCamera,
                        onPhotoLibrary: onPhotoLibrary,
                        onDocument: onDocument,
                        onGIF: onGIF
                    )
                    TextField(disabledReason ?? (isEditing ? "Edit message" : "Message"), text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .focused($isFocused)
                        .disabled(isDisabled)
                }

                if hasText || isEditing {
                    Button(action: onSend) {
                        if isSending {
                            ProgressView()
                        } else {
                            Image(systemName: isEditing ? "checkmark.circle.fill" : "arrow.up.circle.fill").font(.title)
                        }
                    }
                    .disabled(isDisabled || !hasText || isSending)
                    .accessibilityLabel(isEditing ? "Save edit" : "Send")
                } else {
                    VoiceRecordButton(
                        recorder: voiceRecorder,
                        isDisabled: isDisabled || isSending || isSendingMedia,
                        onFinished: onVoiceFinished
                    )
                }
            }
        }
    }
}
