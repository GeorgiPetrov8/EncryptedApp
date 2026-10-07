import SwiftUI
import AVKit
import ImageIO

// MARK: - Video bubble

/// A video message: tap to decrypt and play full screen.
struct VideoMessageView: View {
    let onPlay: () async -> Void
    @State private var isLoading = false

    var body: some View {
        Button {
            guard !isLoading else { return }
            Task {
                isLoading = true
                await onPlay()
                isLoading = false
            }
        } label: {
            ZStack {
                LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                        Text("Video").font(.caption)
                    }
                    .foregroundStyle(.white)
                }
            }
            .frame(width: 200, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play video")
    }
}

/// Full-screen player for a decrypted temporary file; `onClose` deletes it.
struct VideoPlayerScreen: View {
    let url: URL
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .padding()
            }
            .accessibilityLabel("Close")
        }
        .onAppear {
            // `.playback` so the video has sound with the silent switch on.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            onClose()
        }
    }
}

// MARK: - Document bubble

struct FileMessageView: View {
    let title: String
    let textColor: Color
    let bubbleColor: Color
    let onOpen: () async -> Void
    @State private var isLoading = false

    var body: some View {
        Button {
            guard !isLoading else { return }
            Task {
                isLoading = true
                await onOpen()
                isLoading = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                    Text("Tap to open or save")
                        .font(.caption)
                }
                if isLoading { ProgressView() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(bubbleColor)
            .foregroundStyle(textColor)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Share sheet

/// The system share sheet: "Save Image", "Save Video", "Save to Files", AirDrop…
struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Reactions

struct ReactionBar: View {
    let reactions: [ReactionSummary]
    let onTap: (ReactionSummary) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { reaction in
                Button {
                    onTap(reaction)
                } label: {
                    HStack(spacing: 2) {
                        Text(reaction.emoji)
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .font(.caption2.bold())
                                .foregroundStyle(.primary)
                        }
                    }
                    .font(.footnote)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(reaction.includesMe ? Color.brand : .clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(reaction.emoji) \(reaction.count)\(reaction.includesMe ? ", including you" : "")")
            }
        }
    }
}

// MARK: - GIFs

/// A GIF message. Loads from the provider automatically only if the user
/// turned GIFs on; otherwise asks first, because loading reveals their IP
/// address to the provider.
struct GIFMessageView: View {
    let gif: GIFAttachment
    let autoload: Bool
    @State private var loadRequested = false

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if !gif.isTrustedSource {
            placeholder(icon: "exclamationmark.triangle", text: "GIF unavailable")
        } else if autoload || loadRequested {
            AnimatedGIFView(url: gif.displayURL)
        } else {
            Button {
                loadRequested = true
            } label: {
                placeholder(icon: "play.rectangle", text: "GIF · tap to load\nfrom \(gif.providerName)")
            }
            .buttonStyle(.plain)
        }
    }

    private var size: CGSize {
        let width: CGFloat = 220
        guard gif.width > 0, gif.height > 0 else { return CGSize(width: width, height: 160) }
        let height = width * CGFloat(gif.height) / CGFloat(gif.width)
        return CGSize(width: width, height: min(max(height, 110), 300))
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2)
            Text(text).font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
    }
}

/// Plays an animated GIF. (`Image` and `AsyncImage` only show the first frame.)
struct AnimatedGIFView: View {
    let url: URL
    var maxPixelSize: CGFloat = 480

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                AnimatedImageRepresentable(image: image)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.tertiarySystemBackground))
        .task(id: url) {
            image = await GIFLoader.shared.image(for: url, maxPixelSize: maxPixelSize)
            failed = image == nil
        }
    }
}

private struct AnimatedImageRepresentable: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image {
            view.image = image
            view.startAnimating()
        }
    }
}

/// Downloads and decodes GIFs into animated images, with a memory cache.
@MainActor
final class GIFLoader {
    static let shared = GIFLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private static let maxBytes = 8 * 1024 * 1024
    private static let maxFrames = 150

    private init() {
        cache.totalCostLimit = 60 * 1024 * 1024
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= Self.maxBytes else { return nil }

        let image = await Task.detached(priority: .userInitiated) {
            Self.decode(data, maxPixelSize: maxPixelSize)
        }.value
        if let image {
            let cost = Int(image.size.width * image.size.height * 4) * max(image.images?.count ?? 1, 1)
            cache.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }

    private nonisolated static func decode(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), maxFrames)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard count > 1 else {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: frame)
        }

        var frames: [UIImage] = []
        var duration: Double = 0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            frames.append(UIImage(cgImage: frame))
            duration += frameDelay(source, index)
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }

    private nonisolated static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0.1
        // Browsers treat very small delays as 0.1 s; do the same.
        return delay < 0.02 ? 0.1 : delay
    }
}
