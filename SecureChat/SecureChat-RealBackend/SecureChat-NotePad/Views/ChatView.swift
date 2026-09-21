import SwiftUI
import PhotosUI

struct ChatView: View {
    /// FIX (shared notepad): now stored, not just taken by `init` and
    /// discarded after building `viewModel`. `NotePadView` needs
    /// `container.notePadService` at its own construction time (see that
    /// view's doc comment), so `ChatView` has to be able to hand `container`
    /// onward when the sheet is presented.
    let container: AppContainer

    @StateObject private var viewModel: ChatViewModel
    @State private var showVerifyIdentity = false
    @State private var showNotePad = false

    init(container: AppContainer, conversation: Conversation) {
        self.container = container
        _viewModel = StateObject(
            wrappedValue: ChatViewModel(
                conversation: conversation,
                messageRepository: container.messageRepository,
                messagingService: container.messagingService,
                authService: container.authService
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.peerIdentityChanged {
                IdentityChangedBanner(username: viewModel.peerUsername) {
                    showVerifyIdentity = true
                }
            }

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
                    if let last = viewModel.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

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
                    action: viewModel.canRetryLastSend
                        ? .init(title: "Retry", handler: { Task { await viewModel.retryLastSend() } })
                        : nil
                )
            }

            MessageInputBar(
                text: $viewModel.draftText,
                selectedPhotoItem: $viewModel.selectedPhotoItem,
                isSending: viewModel.isSending,
                isSendingMedia: viewModel.isSendingMedia,
                isDisabled: viewModel.peerIdentityChanged
            ) {
                Task { await viewModel.send() }
            }
        }
        .navigationTitle(viewModel.peerUsername)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // FIX (shared notepad): entry point to the pad, with a badge
            // showing how many items are still outstanding — enough to
            // notice "there's something to check" without opening the
            // sheet, the same glanceable purpose the verification-shield
            // icon next to it already serves for identity state.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showNotePad = true
                } label: {
                    Image(systemName: "checklist")
                }
                .accessibilityLabel("Shared pad")
                .overlay(alignment: .topTrailing) {
                    if notePadBadgeCount > 0 {
                        Text("\(notePadBadgeCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(.red))
                            .offset(x: 8, y: -8)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showVerifyIdentity = true
                } label: {
                    Image(systemName: verificationIcon)
                        .foregroundStyle(verificationTint)
                }
                .accessibilityLabel("Verify contact identity")
            }
        }
        .sheet(isPresented: $showVerifyIdentity, onDismiss: { viewModel.reloadPeer() }) {
            if let peerId = viewModel.peerId {
                VerifyIdentityView(peerId: peerId, peerUsername: viewModel.peerUsername)
            }
        }
        // FIX (shared notepad): presented independently of
        // `showVerifyIdentity` — both are sheets on the same `ChatView`,
        // and SwiftUI only supports one `.sheet` modifier being "active" at
        // a time per presentation *source*, but since these are two
        // separate `.sheet(isPresented:)` calls bound to two separate
        // `@State` flags, they don't conflict with each other.
        .sheet(isPresented: $showNotePad) {
            NotePadView(container: container, conversation: viewModel.conversation)
        }
        .onAppear { viewModel.reloadPeer() }
    }

    /// FIX (shared notepad): read directly from `container.notePadService`
    /// rather than `viewModel`, since the pad's item count has nothing to
    /// do with `ChatViewModel`'s chat-message state — deliberately keeping
    /// the two features' view models from needing to know about each other.
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

private struct NoticeBar: View {
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
            if let action {
                Button(action.title, action: action.handler)
                    .font(.footnote.bold())
                    .buttonStyle(.bordered)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(tint.opacity(0.12))
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
    let isSending: Bool
    let isSendingMedia: Bool
    let isDisabled: Bool
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if isSendingMedia {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Sending photo…").font(.caption2)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 6)
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .foregroundStyle(isDisabled || isSendingMedia ? .secondary : .accentColor)
                }
                .disabled(isDisabled || isSendingMedia)
                .accessibilityLabel("Attach photo")

                TextField(isDisabled ? "Verification required" : "Message", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(isDisabled)

                Button(action: onSend) {
                    if isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(isDisabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            .padding()
        }
        .background(.bar)
    }
}
