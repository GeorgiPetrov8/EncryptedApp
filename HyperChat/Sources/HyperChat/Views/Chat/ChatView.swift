import SwiftUI
import PhotosUI

struct ChatView: View {
    let container: AppContainer

    @StateObject private var viewModel: ChatViewModel
    @ObservedObject private var appearanceStore: AppearanceStore
    @ObservedObject private var presenceService: PresenceService
    @ObservedObject private var profileService: ProfileService

    @Environment(\.dismiss) private var dismiss

    @State private var showVerifyIdentity = false
    @State private var showNotePad = false
    @State private var showAppearanceSettings = false
    @State private var showCameraPicker = false
    @State private var showDocumentPicker = false
    @State private var showGIFPicker = false

    init(container: AppContainer, conversation: Conversation) {
        self.container = container
        _appearanceStore = ObservedObject(wrappedValue: container.appearanceStore)
        _presenceService = ObservedObject(wrappedValue: container.presenceService)
        _profileService = ObservedObject(wrappedValue: container.profileService)
        _viewModel = StateObject(
            wrappedValue: ChatViewModel(
                conversation: conversation,
                messageRepository: container.messageRepository,
                conversationRepository: container.conversationRepository,
                messagingService: container.messagingService,
                authService: container.authService,
                receiptService: container.receiptService,
                invitationService: container.invitationService
            )
        )
    }

    // MARK: Body (split into sub-views to keep the type checker fast)

    var body: some View {
        VStack(spacing: 0) {
            identityBanner
            invitationBanner
            messageList
            noticeBars
            inputBar
        }
        .background { chatBackground }
        .environment(\.chatAppearance, appearance)
        .navigationTitle(viewModel.peerUsername)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showVerifyIdentity, onDismiss: { viewModel.reloadPeer() }) {
            verifyIdentitySheet
        }
        .sheet(isPresented: $showNotePad) {
            NotePadView(container: container, conversation: viewModel.conversation)
        }
        .sheet(isPresented: $showAppearanceSettings) {
            AppearanceSettingsView(conversationId: viewModel.conversation.id)
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
            GIFPickerView { data in
                Task { await viewModel.sendGIF(data) }
            }
            .environmentObject(container)
        }
        .onAppear {
            viewModel.reloadConversation()
            viewModel.reloadPeer()
            viewModel.setVisible(true)
            Task { await container.profileService.ensureShared(with: viewModel.conversation) }
        }
        .onDisappear { viewModel.setVisible(false) }
        // Declining deletes the conversation — go back to the list.
        .onChange(of: viewModel.wasRemoved) { _, removed in
            if removed { dismiss() }
        }
    }

    // MARK: Appearance

    private var appearance: ChatAppearance {
        appearanceStore.appearance(for: viewModel.conversation.id)
    }

    private var chatBackground: some View {
        ChatBackgroundView(appearance: appearance) { appearanceStore.imageURL(fileName: $0) }
    }

    // MARK: Banners

    @ViewBuilder
    private var identityBanner: some View {
        if viewModel.peerIdentityChanged {
            IdentityChangedBanner(username: viewModel.peerUsername) {
                showVerifyIdentity = true
            }
        }
    }

    /// FIX (invitations): explains the chat's state and offers the next step.
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
                    .buttonStyle(.borderedProminent)
                Button("Decline", role: .destructive) { Task { await viewModel.declineInvitation() } }
                    .buttonStyle(.bordered)
            }

        case .invitedByMe:
            InvitationBanner(
                icon: "hourglass",
                title: "Waiting for \(viewModel.peerUsername) to accept",
                detail: "You can write now — your messages will be sent as soon as they accept.",
                isBusy: viewModel.isUpdatingInvitation
            ) {
                Button("Resend invitation") { Task { await viewModel.resendInvitation() } }
                    .buttonStyle(.bordered)
            }

        case .declined:
            InvitationBanner(
                icon: "xmark.circle",
                title: "\(viewModel.peerUsername) declined your invitation",
                detail: nil,
                isBusy: viewModel.isUpdatingInvitation
            ) {
                Button("Invite again") { Task { await viewModel.resendInvitation() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.messages) { message in
                        MessageBubbleView(
                            message: message,
                            peerIsVerified: viewModel.peerIsVerified,
                            mediaLoader: { await viewModel.loadMediaData(forMessageId: $0) }
                        )
                        .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                guard let last = viewModel.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
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
        }

        if let error = viewModel.errorMessage {
            NoticeBar(
                text: error,
                tint: .red,
                icon: "xmark.octagon.fill",
                onDismiss: { viewModel.dismissSendError() },
                action: retryAction
            )
        }
    }

    private var retryAction: NoticeBar.Action? {
        guard viewModel.canRetryLastSend else { return nil }
        return NoticeBar.Action(title: "Retry") {
            Task { await viewModel.retryLastSend() }
        }
    }

    private var inputBar: some View {
        MessageInputBar(
            text: $viewModel.draftText,
            selectedPhotoItem: $viewModel.selectedPhotoItem,
            isSending: viewModel.isSending,
            isSendingMedia: viewModel.isSendingMedia,
            disabledReason: viewModel.composeDisabledReason,
            onSend: { Task { await viewModel.send() } },
            onCamera: { showCameraPicker = true },
            onDocument: { showDocumentPicker = true },
            onGIF: { showGIFPicker = true },
            onVoiceFinished: { voiceMessage in
                Task { await viewModel.sendVoiceMessage(voiceMessage) }
            }
        )
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            peerHeader
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            callMenu
            notePadButton
            moreMenu
        }
    }

    /// FIX (calls): the entry point. Voice or video, only once the
    /// invitation is accepted.
    private var callMenu: some View {
        Menu {
            Button {
                startCall(video: false)
            } label: {
                Label("Voice call", systemImage: "phone")
            }
            Button {
                startCall(video: true)
            } label: {
                Label("Video call", systemImage: "video")
            }
        } label: {
            Image(systemName: "phone")
        }
        .disabled(!viewModel.canCall)
        .accessibilityLabel("Call")
    }

    private func startCall(video: Bool) {
        Task {
            await container.callService.startCall(in: viewModel.conversation, video: video)
            // Errors before the call screen appears (no permission, WebRTC
            // missing, not accepted) are shown here in the chat.
            if case .idle = container.callService.phase,
               let error = container.callService.consumeError() {
                viewModel.errorMessage = error
            }
        }
    }

    /// Verification and background moved into one menu so the bar isn't
    /// crowded. The icon still turns red when security keys changed.
    private var moreMenu: some View {
        Menu {
            Button {
                showVerifyIdentity = true
            } label: {
                Label("Verify security", systemImage: verificationIcon)
            }
            Button {
                showAppearanceSettings = true
            } label: {
                Label("Chat background", systemImage: "paintbrush")
            }
        } label: {
            Image(systemName: viewModel.peerIdentityChanged ? "exclamationmark.shield.fill" : "ellipsis.circle")
                .foregroundStyle(viewModel.peerIdentityChanged ? Color.red : Color.accentColor)
        }
        .accessibilityLabel("More")
    }

    private var peerHeader: some View {
        HStack(spacing: 8) {
            AvatarView(
                userId: viewModel.peerId ?? viewModel.peerUsername,
                displayName: viewModel.peerUsername,
                imageData: peerAvatarData,
                size: 32,
                isOnline: isPeerOnline
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(viewModel.peerUsername)
                        .font(.headline)
                        .lineLimit(1)
                    if viewModel.peerIsVerified {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                if isPeerOnline {
                    Text("online")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
        .accessibilityElement(children: .combine)
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

    private var notePadButton: some View {
        Button {
            showNotePad = true
        } label: {
            Image(systemName: "checklist")
        }
        .disabled(viewModel.relationshipState != .accepted)
        .accessibilityLabel("Shared pad")
        .overlay(alignment: .topTrailing) {
            notePadBadge
        }
    }

    @ViewBuilder
    private var notePadBadge: some View {
        if notePadBadgeCount > 0 {
            Text("\(notePadBadgeCount)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(Circle().fill(Color.red))
                .offset(x: 8, y: -8)
        }
    }

    @ViewBuilder
    private var verifyIdentitySheet: some View {
        if let peerId = viewModel.peerId {
            VerifyIdentityView(peerId: peerId, peerUsername: viewModel.peerUsername)
        }
    }

    private var notePadBadgeCount: Int {
        container.notePadService
            .items(for: viewModel.conversation.id)
            .filter { !$0.isDeleted && !$0.isDone }
            .count
    }

    private var verificationIcon: String {
        if viewModel.peerIdentityChanged { return "exclamationmark.shield.fill" }
        return viewModel.peerIsVerified ? "checkmark.shield.fill" : "shield"
    }
}

// MARK: - Supporting views

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
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
            Spacer()
            actionButton
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(.bar)
        .background(tint.opacity(0.12))
    }

    @ViewBuilder
    private var actionButton: some View {
        if let action {
            Button(action.title, action: action.handler)
                .font(.footnote.bold())
                .buttonStyle(.bordered)
        }
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
            Label(title, systemImage: icon)
                .font(.subheadline.bold())
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                actions()
                if isBusy { ProgressView() }
            }
            .font(.footnote)
            .disabled(isBusy)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

private struct IdentityChangedBanner: View {
    let username: String
    let onReview: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Security keys for \(username) changed")
                    .font(.footnote.bold())
                Text("Messaging is paused until you review this.")
                    .font(.caption)
            }
            .foregroundStyle(.white)
            Spacer()
            Button("Review", action: onReview)
                .font(.footnote.bold())
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red)
    }
}

private struct MessageInputBar: View {
    @Binding var text: String
    @Binding var selectedPhotoItem: PhotosPickerItem?

    @StateObject private var voiceRecorder = VoiceRecorder()

    let isSending: Bool
    let isSendingMedia: Bool
    /// Non-nil when typing isn't allowed; also used as the placeholder.
    let disabledReason: String?
    let onSend: () -> Void
    let onCamera: () -> Void
    let onDocument: () -> Void
    let onGIF: () -> Void
    let onVoiceFinished: (RecordedVoiceMessage) -> Void

    private var isDisabled: Bool { disabledReason != nil }

    var body: some View {
        VStack(spacing: 0) {
            sendingIndicator
            controls
        }
        .background(.bar)
    }

    @ViewBuilder
    private var sendingIndicator: some View {
        if isSendingMedia {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Sending attachment…")
                    .font(.caption2)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.top, 6)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            attachmentMenu
            if voiceRecorder.isRecording {
                VoiceRecordingBar(recorder: voiceRecorder)
                    .frame(maxWidth: .infinity)
            } else {
                textField
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    voiceButton
                } else {
                    sendButton
                }
            }
        }
        .padding()
    }

    private var attachmentMenu: some View {
        AttachmentMenu(
            selectedPhotoItem: $selectedPhotoItem,
            isDisabled: isDisabled || isSendingMedia,
            onCamera: onCamera,
            onDocument: onDocument,
            onGIF: onGIF
        )
    }

    private var textField: some View {
        TextField(disabledReason ?? "Message", text: $text, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            .disabled(isDisabled)
    }

    private var sendButton: some View {
        Button(action: onSend) {
            sendButtonLabel
        }
        .disabled(isSendDisabled)
    }

    private var voiceButton: some View {
        VoiceRecordButton(
            recorder: voiceRecorder,
            isDisabled: isDisabled || isSending || isSendingMedia,
            onFinished: onVoiceFinished
        )
    }

    @ViewBuilder
    private var sendButtonLabel: some View {
        if isSending {
            ProgressView()
        } else {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
        }
    }

    private var isSendDisabled: Bool {
        isDisabled
            || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isSending
    }
}
