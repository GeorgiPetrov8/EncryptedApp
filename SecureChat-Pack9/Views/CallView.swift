import SwiftUI
import AVFoundation

#if canImport(WebRTC)
import WebRTC
#endif

/// Full-screen call UI (feature: calls and screen sharing).
struct CallView: View {
    @EnvironmentObject private var container: AppContainer
    let peerName: String

    private var service: CallService { container.callService }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            remoteVideo

            VStack {
                header
                Spacer()
                controls
            }
            .padding()

            if case .incoming = service.phase {
                incomingOverlay
            }
        }
        .preferredColorScheme(.dark)
        // Calls keep the screen awake — nothing else in the app does, so this
        // is scoped to the call rather than set globally.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Video

    @ViewBuilder
    private var remoteVideo: some View {
        #if canImport(WebRTC)
        if service.remoteIsVideoEnabled || service.remoteIsScreenSharing {
            RTCVideoView(isScreenShare: service.remoteIsScreenSharing)
                .ignoresSafeArea()
        } else {
            audioOnlyBackdrop
        }
        #else
        audioOnlyBackdrop
        #endif

        // Local preview, picture-in-picture. Mirrored, because an unmirrored
        // self-view feels wrong to everyone who has ever used a mirror.
        if service.isVideoEnabled {
            VStack {
                HStack {
                    Spacer()
                    #if canImport(WebRTC)
                    RTCVideoView(isLocal: true)
                        .frame(width: 100, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.2)))
                        .padding()
                    #endif
                }
                Spacer()
            }
        }
    }

    private var audioOnlyBackdrop: some View {
        VStack(spacing: 16) {
            AvatarView(userId: peerName, displayName: peerName, imageData: nil, size: 120)
            Text(peerName).font(.title2.bold()).foregroundStyle(.white)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 4) {
            Text(peerName)
                .font(.headline)
                .foregroundStyle(.white)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            if service.remoteIsScreenSharing {
                Label("Sharing their screen", systemImage: "rectangle.inset.filled.on.rectangle")
                    .font(.caption2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.top, 40)
    }

    private var statusText: String {
        switch service.phase {
        case .idle: return ""
        case .outgoing: return "Calling…"
        case .incoming(_, let isVideo, _): return isVideo ? "Incoming video call" : "Incoming call"
        case .connecting: return "Connecting…"
        case .active:
            guard let connectedAt = service.connectedAt else { return "Connected" }
            let elapsed = Int(Date().timeIntervalSince(connectedAt))
            return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        case .ended(let reason):
            switch reason {
            case .declined: return "Call declined"
            case .busy: return "Busy"
            case .unanswered: return "No answer"
            case .failed: return "Call failed"
            case .hangUp: return "Call ended"
            }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if case .incoming = service.phase {
            EmptyView() // the incoming overlay owns the buttons
        } else {
            HStack(spacing: 24) {
                controlButton(
                    icon: service.isAudioMuted ? "mic.slash.fill" : "mic.fill",
                    active: service.isAudioMuted
                ) {
                    service.toggleMute()
                }
                .accessibilityLabel(service.isAudioMuted ? "Unmute" : "Mute")

                controlButton(
                    icon: service.isVideoEnabled ? "video.fill" : "video.slash.fill",
                    active: !service.isVideoEnabled
                ) {
                    Task { await service.toggleVideo() }
                }
                .accessibilityLabel(service.isVideoEnabled ? "Turn off camera" : "Turn on camera")

                controlButton(
                    icon: "rectangle.inset.filled.on.rectangle",
                    active: service.isScreenSharing
                ) {
                    Task { await service.toggleScreenShare() }
                }
                .accessibilityLabel(service.isScreenSharing ? "Stop sharing screen" : "Share screen")

                Button {
                    Task { await service.hangUp() }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(.red))
                }
                .accessibilityLabel("End call")
            }
            .padding(.bottom, 40)
        }
    }

    private func controlButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(active ? .black : .white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(active ? .white : .white.opacity(0.2)))
        }
    }

    // MARK: Incoming

    private var incomingOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 60) {
                Button {
                    Task { await service.decline() }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "phone.down.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(.red))
                        Text("Decline").font(.caption).foregroundStyle(.white)
                    }
                }

                Button {
                    Task { await service.answer() }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "phone.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(.green))
                        Text("Accept").font(.caption).foregroundStyle(.white)
                    }
                }
            }
            .padding(.bottom, 60)
        }
    }
}

#if canImport(WebRTC)
/// Bridges `RTCMTLVideoView` into SwiftUI.
///
/// Metal-backed rather than the OpenGL variant: the OpenGL renderer is
/// deprecated on iOS and drops frames on newer devices.
struct RTCVideoView: UIViewRepresentable {
    var isLocal = false
    var isScreenShare = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        // A shared screen is usually a document or a slide, where cropping
        // loses the edges that matter. Camera video fills instead, because
        // letterboxed faces look worse than slightly cropped ones.
        view.videoContentMode = isScreenShare ? .scaleAspectFit : .scaleAspectFill
        // The self-view is mirrored to match what a mirror would show.
        view.transform = isLocal ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}
#endif
