import SwiftUI

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @State private var showVerifyIdentity = false

    init(container: AppContainer, conversation: Conversation) {
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
            // FIX (Bug #2): blocking banner when the peer's identity keys changed.
            if viewModel.peerIdentityChanged {
                IdentityChangedBanner(username: viewModel.peerUsername) {
                    showVerifyIdentity = true
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.messages) { message in
                            MessageBubbleView(message: message, peerIsVerified: viewModel.peerIsVerified)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _ in
                    if let last = viewModel.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            // FIX (Bug #9): receive-side failures are now visible instead of being
            // swallowed by `try?` in the listener loop.
            if let receiveError = viewModel.receiveError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(receiveError)
                        .font(.footnote)
                    Spacer()
                    Button {
                        viewModel.dismissReceiveError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Dismiss")
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            MessageInputBar(
                text: $viewModel.draftText,
                isSending: viewModel.isSending,
                isDisabled: viewModel.peerIdentityChanged
            ) {
                Task { await viewModel.send() }
            }
        }
        .navigationTitle(viewModel.peerUsername)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // FIX (Bug #2): entry point to out-of-band verification.
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
        .onAppear { viewModel.reloadPeer() }
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
    let isSending: Bool
    let isDisabled: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 8) {
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
        .background(.bar)
    }
}
