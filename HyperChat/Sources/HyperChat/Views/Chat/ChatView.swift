import SwiftUI
import PhotosUI

struct ChatView: View {
    /// Stored, not just taken by `init` and discarded after building
    /// `viewModel`. `NotePadView` needs `container.notePadService` at its
    /// own construction time, so `ChatView` has to be able to hand
    /// `container` onward when the sheet is presented.
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

    // MARK: Body
    //
    // FIX: split into computed sub-views.
    //
    // This previously failed to compile with "unable to type-check this
    // expression in reasonable time". Nothing was wrong with the logic —
    // SwiftUI's `ViewBuilder` produces a deeply nested generic type
    // (`VStack<TupleView<(A, B, _ConditionalContent<C, D>, ...)>>`), and
    // Swift's type checker explores that space combinatorially. Each
    // additional `if` branch, ternary, or inferred `.init` roughly
    // multiplies the work, so a body that is merely "a bit long" can tip
    // from fast to effectively unbounded.
    //
    // Breaking it into separate computed properties gives the type checker
    // a fixed, already-resolved type at each boundary (`some View`), so it
    // solves several small problems instead of one enormous one. Splitting
    // is the standard remedy — not a workaround.
    var body: some View {
        VStack(spacing: 0) {
            identityBanner
            messageList
            noticeBars
            inputBar
        }
        .navigationTitle(viewModel.peerUsername)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showVerifyIdentity, onDismiss: { viewModel.reloadPeer() }) {
            verifyIdentitySheet
        }
        // Two separate `.sheet(isPresented:)` calls bound to two separate
        // `@State` flags don't conflict with each other.
        .sheet(isPresented: $showNotePad) {
            NotePadView(container: container, conversation: viewModel.conversation)
        }
        .onAppear { viewModel.reloadPeer() }
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

    /// Both notice bars grouped together, so the outer `VStack` sees one
    /// child instead of two more conditional branches.
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

    /// FIX: hoisted out of the `NoticeBar(...)` call.
    ///
    /// Inline, this was `viewModel.canRetryLastSend ? .init(title:...) : nil`
    /// — a ternary whose branches are a leading-dot `.init` and `nil`, both
    /// of which the compiler must infer from the parameter's
    /// `NoticeBar.Action?` type, *while* already solving the surrounding
    /// view hierarchy. An explicitly-typed property removes that inference
    /// from the body entirely.
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
            isDisabled: viewModel.peerIdentityChanged
        ) {
            Task { await viewModel.send() }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            notePadButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            verifyIdentityButton
        }
    }

    /// Entry point to the pad, with a badge showing how many items are
    /// still outstanding — enough to notice "there's something to check"
    /// without opening the sheet.
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

    /// Read directly from `container.notePadService` rather than
    /// `viewModel`, since the pad's item count has nothing to do with
    /// `ChatViewModel`'s chat-message state.
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

/// FIX: no longer `private`.
///
/// `ChatView.retryAction` is an internal computed property whose type is
/// `NoticeBar.Action?`, so `NoticeBar` must be at least as visible as that
/// property. Leaving it `private` would fail with "property cannot be
/// declared internal because its type uses a private type."
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
    let isSending: Bool
    let isSendingMedia: Bool
    let isDisabled: Bool
    let onSend: () -> Void

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
                Text("Sending photo…").font(.caption2)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.top, 6)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            photoPicker
            textField
            sendButton
        }
        .padding()
    }

    private var photoPicker: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Image(systemName: "paperclip")
                .font(.title3)
                .foregroundStyle(attachmentTint)
        }
        .disabled(isDisabled || isSendingMedia)
        .accessibilityLabel("Attach photo")
    }

    /// Hoisted out of the view builder: inline, the ternary had to infer a
    /// common type between `.secondary` (a `HierarchicalShapeStyle`) and
    /// `Color.accentColor`, which are different types — forcing the
    /// compiler to search for a shared `ShapeStyle` conformance mid-body.
    private var attachmentTint: Color {
        (isDisabled || isSendingMedia) ? .secondary : .accentColor
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
