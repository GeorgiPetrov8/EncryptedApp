import SwiftUI

/// Displays an inline image for a media message, decrypting lazily and
/// caching the result so re-rendering during scroll doesn't re-decrypt.
///
/// Deliberately takes a `mediaLoader` closure rather than a reference to
/// `ChatViewModel`/`MessagingService` directly — this keeps the view
/// trivially previewable and testable in isolation, and keeps
/// `MessageBubbleView` (which embeds this) from having to know anything
/// about how decryption actually happens.
struct MediaMessageView: View {
    let messageId: String
    let mediaLoader: (String) async -> Data?

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var failed = false
    @State private var showFullScreen = false

    private let cornerRadius: CGFloat = 16
    private let maxWidth: CGFloat = 240
    private let maxHeight: CGFloat = 320

    var body: some View {
        content
            // Keyed by messageId: if this view instance is ever reused for a
            // different message (SwiftUI does this more than you'd expect
            // inside a LazyVStack), the task restarts instead of silently
            // showing the previous message's cached image.
            .task(id: messageId) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Button {
                showFullScreen = true
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $showFullScreen) {
                FullScreenImageViewer(image: image) { showFullScreen = false }
            }
        } else if failed {
            placeholder(systemImage: "exclamationmark.triangle", label: "Couldn't load photo", tint: .orange)
        } else {
            placeholder(systemImage: "photo", label: isLoading ? "Loading…" : "Photo", tint: .secondary)
        }
    }

    private func placeholder(systemImage: String, label: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: systemImage).font(.title2)
            }
            Text(label).font(.caption)
        }
        .foregroundStyle(tint)
        .frame(width: 160, height: 160)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func load() async {
        guard image == nil else { return }
        if let cached = DecryptedMediaCache.shared.image(forKey: messageId) {
            image = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard let data = await mediaLoader(messageId), let uiImage = UIImage(data: data) else {
            failed = true
            return
        }
        DecryptedMediaCache.shared.store(uiImage, forKey: messageId)
        image = uiImage
    }
}

/// Tap-to-view full screen, with pinch-to-zoom and double-tap-to-reset —
/// small additions on top of the minimum "show the picture bigger", but
/// cheap once the image is already decrypted and in memory.
private struct FullScreenImageViewer: View {
    let image: UIImage
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in scale = max(1, lastScale * value) }
                        .onEnded { _ in lastScale = scale }
                )
                .onTapGesture(count: 2) {
                    withAnimation { scale = 1; lastScale = 1 }
                }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .black.opacity(0.4))
                    .padding()
            }
            .accessibilityLabel("Close")
        }
        .statusBarHidden()
    }
}
