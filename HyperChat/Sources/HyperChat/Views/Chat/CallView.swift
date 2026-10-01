import SwiftUI
import AVFoundation

#if canImport(WebRTC)
import WebRTC
#endif

/// Full-screen call UI. Presented by `ConversationListView` whenever a call is
/// in progress, so it appears no matter which screen you're on.
struct CallView: View {
    @EnvironmentObject private var container: AppContainer

    private var service: CallService { container.callService }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            remoteVideo
            localPreview

            VStack {
                header
                Spacer()
                if let error = service.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 12)
                }
                controls
            }
            .padding()

            if case .incoming = service.phase {
                incomingOverlay
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Peer

    private var peerId: String? { service.activePeerId }

    private var peer: User? {
        guard let me = container.authService.currentUserId, let peerId else { return nil }
        return try? container.userRepository.fetch(ownerUserId: me, id: peerId)
    }

    private var peerName: String {
        peer?.shownName ?? String((peerId ?? "").prefix(8))
    }

    // MARK: Video

    @ViewBuilder
    private var remoteVideo: some View {
        #if canImport(WebRTC)
        if (service.remoteIsVideoEnabled || service.remoteIsScreenSharing), let track = service.remoteVideoTrack {
            RTCVideoView(track: track, isScreenShare: service.remoteIsScreenSharing)
                .ignoresSafeArea()
        } else {
            audioOnlyBackdrop
        }
        #else
        audioOnlyBackdrop
        #endif
    }

    @ViewBuilder
    private var localPreview: some View {
        #if canImport(WebRTC)
        if service.isVideoEnabled, let track = service.localVideoTrack {
            VStack {
                HStack {
                    Spacer()
                    RTCVideoView(track: track, isLocal: true)
                        .frame(width: 100, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.2)))
                        .padding(.top, 50)
                }
                Spacer()
            }
            .padding()
        }
        #endif
    }

    private var audioOnlyBackdrop: some View {
        VStack(spacing: 16) {
            AvatarView(
                userId: peerId ?? peerName,
                displayName: peerName,
                imageData: peerId.flatMap { container.profileService.avatarData(for: $0) },
                size: 120
            )
            Text(peerName).font(.title2.bold()).foregroundStyle(.white)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 4) {
            Text(peerName)
                .font(.headline)
                .foregroundStyle(.white)

            // FIX: the elapsed time never ticked — nothing re-rendered the view
            // once a second. `TimelineView` does.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(statusText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }

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
        case .outgoing(_, let isVideo): return isVideo ? "Video calling…" : "Calling…"
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
        switch service.phase {
        case .incoming, .ended, .idle:
            EmptyView()
        case .outgoing, .connecting, .active:
            HStack(spacing: 20) {
                controlButton(
                    icon: service.isAudioMuted ? "mic.slash.fill" : "mic.fill",
                    active: service.isAudioMuted
                ) { service.toggleMute() }
                .accessibilityLabel(service.isAudioMuted ? "Unmute" : "Mute")

                controlButton(
                    icon: service.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                    active: service.isSpeakerOn
                ) { service.toggleSpeaker() }
                .accessibilityLabel(service.isSpeakerOn ? "Speaker off" : "Speaker on")

                // Only on video calls: video can't be added to a voice call yet.
                if service.isVideoCall {
                    controlButton(
                        icon: service.isVideoEnabled ? "video.fill" : "video.slash.fill",
                        active: !service.isVideoEnabled
                    ) { Task { await service.toggleVideo() } }
                    .accessibilityLabel(service.isVideoEnabled ? "Turn off camera" : "Turn on camera")
                }

                controlButton(
                    icon: "rectangle.inset.filled.on.rectangle",
                    active: service.isScreenSharing
                ) { Task { await service.toggleScreenShare() } }
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
                .background(Circle().fill(active ? Color.white : Color.white.opacity(0.2)))
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
/// Bridges `RTCMTLVideoView` into SwiftUI and attaches it to a track.
///
/// FIX: the previous version created the view but never called
/// `track.add(view)`, so it had no frames to draw. The coordinator remembers
/// which track the view is attached to, re-attaches when the track changes,
/// and detaches when the view goes away (otherwise the track keeps a dead
/// renderer around).
struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    var isLocal = false
    var isScreenShare = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        configure(view)
        track.add(view)
        context.coordinator.track = track
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        configure(view)
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(view)
            track.add(view)
            context.coordinator.track = track
        }
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        coordinator.track = nil
    }

    private func configure(_ view: RTCMTLVideoView) {
        // A shared screen is usually a document — don't crop its edges.
        view.videoContentMode = isScreenShare ? .scaleAspectFit : .scaleAspectFill
        // The self-view is mirrored, like a mirror.
        view.transform = isLocal ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    final class Coordinator {
        var track: RTCVideoTrack?
    }
}
#endif
