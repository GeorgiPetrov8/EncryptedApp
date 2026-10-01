import SwiftUI
import PhotosUI

struct ChatView: View {
    let container: AppContainer

    @StateObject private var viewModel: ChatViewModel

    // FIX: observed directly, so a saved background, a presence change or a
    // new avatar redraws this screen. `container` alone is a plain `let` here
    // and wouldn't trigger updates.
    @ObservedObject private var appearanceStore: AppearanceStore
    @ObservedObject private var presenceService: PresenceService
    @ObservedObject private var profileService: ProfileService

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
                messagingService: container.messagingService,
                authService: container.authService,
                receiptService: container.receiptService
            )
        )
    }

    // MARK: Body
    //
    // Split into computed sub-views to keep the type checker fast.

    var body: some View {
        VStack(spacing: 0) {
            identityBanner
            messageList
            noticeBars
            inputBar
        }
        // FIX (problem 1): the saved background is actually rendered now, and
        // the resolved appearance flows to every bubble via the environment.
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
            viewModel.reloadPeer()
            viewModel.setVisible(true)
            Task { await container.profileService.ensureShared(with: viewModel.conversation) }
        }
        .onDisappear { viewModel.setVisible(false) }
    }

    // MARK: Appearance

    private var appearance: ChatAppearance {
        appearanceStore.appearance(for: viewModel.conversation.id)
    }

    private var chatBackground: some View {
        ChatBackgroundView(appearance: appearance) { appearanceStore.imageURL(fileName: $0) }
    }

    // MARK: Sections

    @ViewBuilder
    private var identityBanner: some View {
        if viewModel.peerIdentityChanged {
            IdentityChangedBanner(username: viewModel.peerUsername) {
                showVerifyIdentity = true
            }
        }
    }

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
            isDisabled: viewModel.peerIdentityChanged,
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
        // FIX (problems 3 & 4): avatar + online status in the title area.
        ToolbarItem(placement: .principal) {
            peerHeader
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            notePadButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            verifyIdentityButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showAppearanceSettings = true
            } label: {
                Image(systemName: "paintbrush")
            }
            .accessibilityLabel("Chat appearance")
        }
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
                Text(viewModel.peerUsername)
                    .font(.headline)
                    .lineLimit(1)
                // Only "online" is ever shown — never "offline" or "last seen".
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
        // Reading `version` ties this to avatar updates.
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

    private var verifyIdentityButton: some View {
        Button {
            showVerifyIdentity = true
        } label: {
            Image(systemName: verificationIcon)
                .foregroundStyle(verificationTint)
        }
        .accessibilityLabel("Verify contact identity")
    }

    @ViewBuilder
    private var verifyIdentitySheet: some View {
        if let peerId = viewModel.peerId {
            VerifyIdentityView(peerId: peerId, peerUsername: viewModel.peerUsername)
        }
    }

    // MARK: Derived values

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

    private var verificationTint: Color {
        if viewModel.peerIdentityChanged { return .red }
        return viewModel.peerIsVerified ? .green : .secondary
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
    let isDisabled: Bool
    let onSend: () -> Void
    let onCamera: () -> Void
    let onDocument: () -> Void
    let onGIF: () -> Void
    let onVoiceFinished: (RecordedVoiceMessage) -> Void

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
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            .disabled(isDisabled)
    }

    private var placeholder: String {
        isDisabled ? "Verification required" : "Message"
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
