import SwiftUI

/// Displays an inline image for a media message, decrypting lazily and caching
/// the result so re-rendering during scroll doesn't re-decrypt.
///
/// Takes a `mediaLoader` closure rather than a reference to the view model, so the
/// view stays previewable and `MessageBubbleView` knows nothing about decryption.
struct MediaMessageView: View {
    let messageId: String
    let mediaLoader: (String) async -> Data?

    @Environment(\.appTheme) private var theme

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var failed = false
    @State private var showFullScreen = false

    private let cornerRadius: CGFloat = 16
    private let maxWidth: CGFloat = 240
    private let maxHeight: CGFloat = 320

    var body: some View {
        content
            // Keyed by messageId: if this view instance is reused for another
            // message, the task restarts instead of showing the old image.
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
            placeholder(systemImage: "exclamationmark.triangle", label: "Couldn't load photo", isWarning: true)
        } else {
            placeholder(systemImage: "photo", label: isLoading ? "Loading…" : "Photo", isWarning: false)
        }
    }

    /// FIX: the placeholder used `secondarySystemBackground` and grey text, so it
    /// looked like a different surface from the bubbles around it. It now uses the
    /// incoming-bubble colours of the chat's theme.
    private func placeholder(systemImage: String, label: String, isWarning: Bool) -> some View {
        VStack(spacing: 6) {
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: systemImage).font(.title2)
            }
            Text(label).font(.caption.weight(theme.isCustom ? .semibold : .regular))
        }
        .foregroundStyle(isWarning && !theme.isCustom ? Color.orange : theme.text)
        .frame(width: 160, height: 160)
        .background(theme.incomingBubbleFill)
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

/// Tap-to-view full screen, with pinch-to-zoom and double-tap-to-reset.
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
