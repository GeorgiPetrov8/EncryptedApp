import Foundation
import Combine
import AVFoundation
import os

#if canImport(WebRTC)
import WebRTC
#endif

/// Orchestrates calls: signalling over the encrypted channel, media over
/// WebRTC (feature: audio/video calls and screen sharing).
///
/// ## Dependency
///
/// This needs `stasel/WebRTC` (the maintained SPM distribution of Google's
/// `libwebrtc`), added to `project.yml`:
///
/// ```yaml
/// packages:
///   WebRTC:
///     url: https://github.com/stasel/WebRTC.git
///     from: 120.0.0
/// ```
///
/// It is guarded by `#if canImport(WebRTC)` so the project still builds
/// before the package is added — the call buttons then report that calling
/// isn't available in this build, rather than failing to compile.
///
/// I could not build or run this here (no Xcode, no iOS SDK), and WebRTC has
/// more integration surface than anything else in this project. Treat the
/// media plumbing as needing a real device test, unlike the signalling and
/// state machine, which are ordinary Swift.
@MainActor
final class CallService: NSObject, ObservableObject {

    @Published private(set) var phase: CallPhase = .idle
    @Published private(set) var isAudioMuted = false
    @Published private(set) var isVideoEnabled = false
    @Published private(set) var isScreenSharing = false
    @Published private(set) var remoteIsScreenSharing = false
    @Published private(set) var remoteIsVideoEnabled = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var connectedAt: Date?

    private let authService: AuthService
    private let userRepository: UserRepository
    private let conversationRepository: ConversationRepository
    private let logger = Logger(subsystem: "com.HyperChat", category: "call")

    /// Injected by `AppContainer`, same pattern as the other services — this is
    /// built before `MessagingService`, which holds it.
    private var sendHandler: ((CallSignal, Conversation) async throws -> Void)?

    private var activeConversation: Conversation?
    private var activePeerId: String?
    private var ringTimeoutTask: Task<Void, Never>?

    /// ICE candidates that arrive before the remote description is set.
    ///
    /// This is a real ordering hazard, not a theoretical one: candidates are
    /// emitted as soon as gathering starts and routinely overtake the
    /// offer/answer they belong to. Adding one before the remote description
    /// exists throws, so they're buffered and flushed afterwards.
    private var pendingRemoteCandidates: [IceCandidate] = []

    #if canImport(WebRTC)
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private var videoCapturer: RTCCameraVideoCapturer?

    /// One factory for the process. Creating several is a documented way to
    /// get audio-unit conflicts and crashes in libwebrtc.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()
    #endif

    init(
        authService: AuthService,
        userRepository: UserRepository,
        conversationRepository: ConversationRepository
    ) {
        self.authService = authService
        self.userRepository = userRepository
        self.conversationRepository = conversationRepository
        super.init()
    }

    func setSendHandler(_ handler: @escaping (CallSignal, Conversation) async throws -> Void) {
        sendHandler = handler
    }

    var isAvailable: Bool {
        #if canImport(WebRTC)
        return true
        #else
        return false
        #endif
    }

    // MARK: Placing a call

    func startCall(in conversation: Conversation, video: Bool) async {
        guard isAvailable else {
            errorMessage = "Calling isn't available in this build."
            return
        }
        guard !phase.isBusy else { return }
        guard conversation.relationshipState.allowsSending else {
            // Calling someone who hasn't accepted an invitation would bypass
            // the gate the invitation feature exists to provide.
            errorMessage = "You can't call someone who hasn't accepted your invitation."
            return
        }
        guard let myUserId = authService.currentUserId,
              let peerId = conversation.otherParticipant(myUserId: myUserId) else { return }

        guard await requestPermissions(video: video) else {
            errorMessage = video
                ? "Camera and microphone access are needed for video calls."
                : "Microphone access is needed for calls."
            return
        }

        let callId = UUID().uuidString
        activeConversation = conversation
        activePeerId = peerId
        isVideoEnabled = video
        phase = .outgoing(callId: callId, isVideo: video)

        #if canImport(WebRTC)
        do {
            let connection = try makePeerConnection()
            peerConnection = connection
            try attachLocalMedia(to: connection, video: video)

            let constraints = RTCMediaConstraints(
                mandatoryConstraints: [
                    "OfferToReceiveAudio": "true",
                    "OfferToReceiveVideo": video ? "true" : "false",
                ],
                optionalConstraints: nil
            )
            let offer = try await connection.offer(for: constraints)
            try await connection.setLocalDescription(offer)

            try await sendHandler?(
                .offer(CallOffer(callId: callId, sdp: offer.sdp, isVideo: video, startedAt: Date())),
                conversation
            )
            startRingTimeout(callId: callId)
        } catch {
            logger.error("Couldn't start the call")
            errorMessage = "Couldn't start the call."
            await endCall(reason: .failed)
        }
        #endif
    }

    // MARK: Answering

    func answer() async {
        guard case .incoming(let callId, let isVideo, _) = phase,
              let conversation = activeConversation else { return }

        guard await requestPermissions(video: isVideo) else {
            await endCall(reason: .declined)
            return
        }

        phase = .connecting(callId: callId)
        isVideoEnabled = isVideo

        #if canImport(WebRTC)
        do {
            guard let connection = peerConnection else { return }
            try attachLocalMedia(to: connection, video: isVideo)

            let constraints = RTCMediaConstraints(
                mandatoryConstraints: [
                    "OfferToReceiveAudio": "true",
                    "OfferToReceiveVideo": isVideo ? "true" : "false",
                ],
                optionalConstraints: nil
            )
            let answer = try await connection.answer(for: constraints)
            try await connection.setLocalDescription(answer)

            try await sendHandler?(
                .answer(CallAnswer(callId: callId, sdp: answer.sdp, isVideo: isVideo)),
                conversation
            )
        } catch {
            logger.error("Couldn't answer the call")
            await endCall(reason: .failed)
        }
        #endif
    }

    func decline() async {
        await endCall(reason: .declined)
    }

    func hangUp() async {
        await endCall(reason: .hangUp)
    }

    // MARK: Mid-call controls

    func toggleMute() {
        isAudioMuted.toggle()
        #if canImport(WebRTC)
        localAudioTrack?.isEnabled = !isAudioMuted
        #endif
        Task { await broadcastState() }
    }

    func toggleVideo() async {
        guard await requestPermissions(video: true) else { return }
        isVideoEnabled.toggle()
        #if canImport(WebRTC)
        localVideoTrack?.isEnabled = isVideoEnabled
        if isVideoEnabled { startCameraCapture() } else { await stopCameraCapture() }
        #endif
        await broadcastState()
    }

    /// Screen sharing.
    ///
    /// iOS only allows capturing the screen from a **Broadcast Upload
    /// Extension** — a separate process started by the system's broadcast
    /// picker. An app cannot grab its own screen, let alone the whole device,
    /// from inside its own process. So this is not a single API call:
    ///
    ///   1. add a Broadcast Upload Extension target;
    ///   2. share an App Group between app and extension;
    ///   3. the extension receives `CMSampleBuffer`s and forwards them to the
    ///      app over the App Group (a socket or shared memory);
    ///   4. the app feeds them into an `RTCVideoSource` in place of the camera.
    ///
    /// `ScreenShareCoordinator` below marks that boundary. Without the
    /// extension target this reports unavailable rather than silently doing
    /// nothing, which is the failure mode that wastes an afternoon.
    func toggleScreenShare() async {
        guard ScreenShareCoordinator.isExtensionConfigured else {
            errorMessage = "Screen sharing needs the broadcast extension, which isn't set up in this build."
            return
        }
        isScreenSharing.toggle()
        await broadcastState()
    }

    private func broadcastState() async {
        guard let conversation = activeConversation, let callId = currentCallId else { return }
        try? await sendHandler?(
            .update(CallStateUpdate(
                callId: callId,
                isAudioMuted: isAudioMuted,
                isVideoEnabled: isVideoEnabled,
                isScreenSharing: isScreenSharing
            )),
            conversation
        )
    }

    private var currentCallId: String? {
        switch phase {
        case .outgoing(let id, _), .incoming(let id, _, _), .connecting(let id), .active(let id):
            return id
        case .idle, .ended:
            return nil
        }
    }

    // MARK: Incoming signals

    func handle(_ signal: CallSignal, from peerId: String, conversation: Conversation) async {
        // A signal from a previous call — a late ICE candidate, a duplicate
        // hang-up — must not disturb the current one.
        if let current = currentCallId, signal.callId != current, case .offer = signal {
            // Except a *new* offer while busy, which gets a busy signal.
            try? await sendHandler?(.end(CallEnd(callId: signal.callId, reason: .busy)), conversation)
            return
        }
        if let current = currentCallId, signal.callId != current { return }

        switch signal {
        case .offer(let offer):
            await receiveOffer(offer, from: peerId, conversation: conversation)
        case .answer(let answer):
            await receiveAnswer(answer)
        case .candidate(let candidate):
            await receiveCandidate(candidate)
        case .end(let end):
            finish(reason: end.reason)
        case .update(let update):
            remoteIsScreenSharing = update.isScreenSharing
            remoteIsVideoEnabled = update.isVideoEnabled
        }
    }

    private func receiveOffer(_ offer: CallOffer, from peerId: String, conversation: Conversation) async {
        guard !phase.isBusy else {
            try? await sendHandler?(.end(CallEnd(callId: offer.callId, reason: .busy)), conversation)
            return
        }
        activeConversation = conversation
        activePeerId = peerId

        #if canImport(WebRTC)
        do {
            let connection = try makePeerConnection()
            peerConnection = connection
            try await connection.setRemoteDescription(
                RTCSessionDescription(type: .offer, sdp: offer.sdp)
            )
            await flushPendingCandidates()
        } catch {
            logger.error("Couldn't accept the incoming offer")
            await endCall(reason: .failed)
            return
        }
        #endif

        phase = .incoming(callId: offer.callId, isVideo: offer.isVideo, peerId: peerId)
        remoteIsVideoEnabled = offer.isVideo
        startRingTimeout(callId: offer.callId)
    }

    private func receiveAnswer(_ answer: CallAnswer) async {
        #if canImport(WebRTC)
        guard let connection = peerConnection else { return }
        do {
            try await connection.setRemoteDescription(
                RTCSessionDescription(type: .answer, sdp: answer.sdp)
            )
            await flushPendingCandidates()
            remoteIsVideoEnabled = answer.isVideo
            phase = .connecting(callId: answer.callId)
            ringTimeoutTask?.cancel()
        } catch {
            logger.error("Couldn't apply the answer")
            await endCall(reason: .failed)
        }
        #endif
    }

    private func receiveCandidate(_ candidate: IceCandidate) async {
        #if canImport(WebRTC)
        guard let connection = peerConnection, connection.remoteDescription != nil else {
            // Arrived before the description it belongs to — buffer it.
            pendingRemoteCandidates.append(candidate)
            return
        }
        try? await connection.add(
            RTCIceCandidate(sdp: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        )
        #endif
    }

    private func flushPendingCandidates() async {
        #if canImport(WebRTC)
        guard let connection = peerConnection else { return }
        for candidate in pendingRemoteCandidates {
            try? await connection.add(
                RTCIceCandidate(sdp: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
            )
        }
        pendingRemoteCandidates.removeAll()
        #endif
    }

    // MARK: Ending

    private func endCall(reason: CallEnd.Reason) async {
        if let conversation = activeConversation, let callId = currentCallId {
            try? await sendHandler?(.end(CallEnd(callId: callId, reason: reason)), conversation)
        }
        finish(reason: reason)
    }

    private func finish(reason: CallEnd.Reason) {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil

        #if canImport(WebRTC)
        Task { await stopCameraCapture() }
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        localVideoTrack = nil
        #endif

        pendingRemoteCandidates.removeAll()
        activeConversation = nil
        activePeerId = nil
        isAudioMuted = false
        isVideoEnabled = false
        isScreenSharing = false
        remoteIsScreenSharing = false
        remoteIsVideoEnabled = false
        connectedAt = nil
        phase = .ended(reason: reason)

        // Returns to idle after a moment so the UI can show why it ended.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if case .ended = phase { phase = .idle }
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startRingTimeout(callId: String) {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CallLimits.ringTimeout))
            guard !Task.isCancelled else { return }
            await self?.endCall(reason: .unanswered)
        }
    }

    // MARK: Permissions and audio session

    private func requestPermissions(video: Bool) async -> Bool {
        let audioGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard audioGranted else { return false }
        guard video else { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    private func configureAudioSession(video: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // `.videoChat` engages echo cancellation and prefers the speaker;
        // `.voiceChat` keeps the earpiece for a phone-to-ear audio call.
        try session.setCategory(
            .playAndRecord,
            mode: video ? .videoChat : .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true)
    }

    #if canImport(WebRTC)
    private func makePeerConnection() throws -> RTCPeerConnection {
        try configureAudioSession(video: isVideoEnabled)

        let config = RTCConfiguration()
        // STUN discovers the public address for a direct peer-to-peer path.
        //
        // No TURN server is configured, and that is a real functional gap:
        // roughly 10–20% of connections — symmetric NAT, restrictive
        // corporate networks, some mobile carriers — cannot be established
        // without a relay. Adding TURN means running (or renting) one, and it
        // relays the *encrypted* media, so it doesn't weaken the call.
        config.iceServers = [RTCIceServer(urlStrings: [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302",
        ])]
        config.sdpSemantics = .unifiedPlan
        // Gathers candidates over a single connection, which connects faster
        // and uses fewer ports than the legacy behaviour.
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw CallError.connectionFailed
        }
        return connection
    }

    private func attachLocalMedia(to connection: RTCPeerConnection, video: Bool) throws {
        let audioSource = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "audio0")
        connection.add(audioTrack, streamIds: ["stream0"])
        localAudioTrack = audioTrack

        guard video else { return }
        let videoSource = Self.factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        let videoTrack = Self.factory.videoTrack(with: videoSource, trackId: "video0")
        connection.add(videoTrack, streamIds: ["stream0"])
        localVideoTrack = videoTrack
        videoCapturer = capturer
        startCameraCapture()
    }

    private func startCameraCapture() {
        guard let capturer = videoCapturer,
              let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
        else { return }

        // 640×480 at 30 fps: enough for a video call, and low enough that the
        // encoder keeps up on older hardware without draining the battery.
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.min { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(da.width) - 640) < abs(Int(db.width) - 640)
        }
        guard let format else { return }
        let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(min(fps, 30)))
    }

    private func stopCameraCapture() async {
        await withCheckedContinuation { continuation in
            guard let capturer = videoCapturer else { return continuation.resume() }
            capturer.stopCapture { continuation.resume() }
        }
    }
    #endif
}

#if canImport(WebRTC)
extension CallService: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard let conversation = self.activeConversation, let callId = self.currentCallId else { return }
            try? await self.sendHandler?(
                .candidate(IceCandidate(
                    callId: callId,
                    sdp: candidate.sdp,
                    sdpMLineIndex: candidate.sdpMLineIndex,
                    sdpMid: candidate.sdpMid
                )),
                conversation
            )
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            switch newState {
            case .connected, .completed:
                if let callId = self.currentCallId {
                    self.phase = .active(callId: callId)
                    if self.connectedAt == nil { self.connectedAt = Date() }
                }
                self.ringTimeoutTask?.cancel()
            case .failed:
                // Distinguished from a hang-up so the UI can say the call
                // dropped rather than implying someone ended it.
                await self.endCall(reason: .failed)
            case .disconnected:
                // Not terminal: ICE recovers from brief network changes, such
                // as Wi-Fi to cellular. Ending here would drop calls that
                // would have survived.
                break
            default:
                break
            }
        }
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
#endif

enum CallError: LocalizedError {
    case connectionFailed
    case unavailable

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Couldn't establish the call."
        case .unavailable: return "Calling isn't available in this build."
        }
    }
}

/// Boundary for the Broadcast Upload Extension that screen sharing requires.
///
/// Kept as an explicit, checkable flag rather than a silent no-op, because the
/// failure otherwise looks like "the button does nothing" — which is the kind
/// of thing that gets debugged for an hour before someone reads the docs.
enum ScreenShareCoordinator {
    /// The App Group shared between app and extension. Both must declare it in
    /// their entitlements; without it the extension cannot hand frames back.
    static let appGroupIdentifier = "group.com.hyperchat.broadcast"

    static var isExtensionConfigured: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil
    }
}
