import SwiftUI

/// Displays an inline image for a media message, decrypting lazily and caching
/// the result so re-rendering during scroll doesn't re-decrypt.
struct MediaMessageView: View {
    let messageId: String
    let mediaLoader: (String) async -> Data?

    @Environment(\.appTheme) private var theme

    @State private var image: UIImage?
    @State private var fullImageData: Data?
    @State private var isLoading = false
    @State private var failed = false
    @State private var showFullScreen = false

    private let cornerRadius: CGFloat = 16
    private let maxWidth: CGFloat = 240
    private let maxHeight: CGFloat = 320

    /// The bubble is at most 320 pt tall; @3x that is under 1 000 px.
    private static let bubblePixelSize: CGFloat = 1_000
    /// Full screen with room to zoom.
    private static let fullScreenPixelSize: CGFloat = 3_000

    var body: some View {
        content
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
                FullScreenImageViewer(
                    image: fullImageData.flatMap { ImageSafety.downsampledImage($0, maxPixelSize: Self.fullScreenPixelSize) } ?? image
                ) { showFullScreen = false }
            }
        } else if failed {
            placeholder(systemImage: "exclamationmark.triangle", label: "Couldn't load photo", isWarning: true)
        } else {
            placeholder(systemImage: "photo", label: isLoading ? "Loading…" : "Photo", isWarning: false)
        }
    }

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

    /// FIX (R22): decoded through ImageIO at display size. `UIImage(data:)` would
    /// decode the full declared resolution when drawn — a small file declaring a
    /// huge image crashed the app every time this chat was opened.
    private func load() async {
        guard image == nil else { return }
        if let cached = DecryptedMediaCache.shared.image(forKey: messageId) {
            image = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard let data = await mediaLoader(messageId) else {
            failed = true
            return
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageSafety.downsampledImage(data, maxPixelSize: Self.bubblePixelSize)
        }.value
        guard let decoded else {
            failed = true
            return
        }
        DecryptedMediaCache.shared.store(decoded, forKey: messageId)
        fullImageData = data
        image = decoded
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
                        .onChanged { value in scale = min(6, max(1, lastScale * value)) }
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
