import SwiftUI
import AVKit

/// #12 / #19: full-screen viewer for a view-once photo/video or a disappearing
/// text. Closing it consumes the message (see `ConsumeOnViewPolicy`).
///
///   - Photo/video: only online; closes by itself if the connection drops.
///   - Hidden while the screen is being recorded or mirrored (`isCaptured`).
///   - A screenshot is reported to the sender (it can't be prevented on iOS).
struct ConsumeOnViewViewer: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let message: Message
    /// Disappearing text: the text itself (already decrypted by the chat).
    let text: String?

    @StateObject private var capture = ScreenCaptureObserver()
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var videoURL: URL?
    @State private var errorMessage: String?
    @State private var loading = false
    /// `close()` and `onDisappear` both run cleanup; consume only once.
    @State private var finished = false

    private var loader: ViewOnceMediaLoader { container.viewOnceLoader }
    private var policy: ConsumeOnViewPolicy { container.consumeOnViewPolicy }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if capture.isCaptured {
                hidden("Hidden while your screen is being recorded or shared.")
            } else if let text {
                ScrollView {
                    Text(text)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.disabled)
                }
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let player {
                VideoPlayer(player: player)
            } else if loading {
                ProgressView().tint(.white)
            } else if let errorMessage {
                hidden(errorMessage)
            }

            VStack {
                HStack {
                    Label("Once", systemImage: "eye")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Button { close() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title)
                    }
                    .accessibilityLabel("Close")
                }
                .foregroundStyle(.white)
                .padding()
                Spacer()
            }
        }
        .statusBarHidden()
        .task { await open() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            policy.reportScreenshot(message)
        }
        .onChange(of: loader.isConnected) { _, connected in
            if !connected, text == nil { close() }
        }
        .onDisappear(perform: cleanup)
    }

    private func hidden(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding()
    }

    private func open() async {
        if text != nil {
            policy.markRevealed(message)
            return
        }
        loading = true
        defer { loading = false }
        do {
            let data = try await loader.load(message)
            if message.contentType == .video {
                let url = ProtectedTemp.url(extension: "mp4", prefix: "once")
                try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
                videoURL = url
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            } else {
                guard let decoded = ImageSafety.downsampledImage(data, maxPixelSize: 2048) else {
                    throw ViewOnceMediaLoader.LoadError.invalid
                }
                image = decoded
            }
            // First frame is on screen: from now on it counts as viewed.
            policy.markRevealed(message)
            loader.startWatching()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func close() {
        cleanup()
        dismiss()
    }

    private func cleanup() {
        guard !finished else { return }
        finished = true
        loader.stopWatching()
        player?.pause()
        player = nil
        image = nil
        if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
        videoURL = nil
        // Consumed only if it was actually shown — an "offline" error doesn't use it up.
        if messageWasRevealed {
            policy.consume(message)
        }
    }

    private var messageWasRevealed: Bool {
        guard let me = container.authService.currentUserId,
              let fresh = try? container.messageRepository.fetch(messageId: message.id, ownerUserId: me)
        else { return false }
        return fresh.revealedAt != nil
    }
}

/// Screen recording / AirPlay mirroring on or off.
@MainActor
final class ScreenCaptureObserver: ObservableObject {
    @Published private(set) var isCaptured = false
    private var token: NSObjectProtocol?

    init() {
        isCaptured = Self.current
        token = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isCaptured = Self.current }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    private static var current: Bool {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.isCaptured ?? false
    }
}
