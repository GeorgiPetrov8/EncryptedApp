import Foundation
import Combine
import AVFoundation
import os

#if canImport(WebRTC)
import WebRTC
#endif

/// Orchestrates calls: signalling over the encrypted channel, media over WebRTC.
@MainActor
final class CallService: NSObject, ObservableObject {

    @Published private(set) var phase: CallPhase = .idle
    @Published private(set) var isAudioMuted = false
    @Published private(set) var isVideoEnabled = false
    @Published private(set) var isSpeakerOn = false
    @Published private(set) var isScreenSharing = false
    @Published private(set) var remoteIsScreenSharing = false
    @Published private(set) var remoteIsVideoEnabled = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var connectedAt: Date?
    @Published private(set) var activePeerId: String?
    @Published private(set) var isVideoCall = false

    #if canImport(WebRTC)
    @Published private(set) var localVideoTrack: RTCVideoTrack?
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    #endif

    private let authService: AuthService
    private let userRepository: UserRepository
    private let conversationRepository: ConversationRepository
    private let logger = Logger(subsystem: "com.HyperChat", category: "call")

    private var sendHandler: ((CallSignal, Conversation) async throws -> Void)?

    private var activeConversation: Conversation?
    private var ringTimeoutTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var pendingRemoteCandidates: [IceCandidate] = []

    /// NEW: screen frames from the broadcast extension.
    private let screenReceiver = ScreenShareReceiver()

    #if canImport(WebRTC)
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    /// Kept so screen frames can be fed into the same video track as the
    /// camera — no renegotiation needed to switch between them.
    private var localVideoSource: RTCVideoSource?
    private var screenCapturer: RTCVideoCapturer?

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

    func consumeError() -> String? {
        defer { errorMessage = nil }
        return errorMessage
    }

    private var currentCallId: String? {
        switch phase {
        case .outgoing(let id, _), .incoming(let id, _, _), .connecting(let id), .active(let id):
            return id
        case .idle, .ended:
            return nil
        }
    }

    // MARK: Placing a call

    func startCall(in conversation: Conversation, video: Bool) async {
        errorMessage = nil
        guard isAvailable else {
            errorMessage = "Calling needs the WebRTC package, which isn't in this build."
            return
        }
        guard !phase.isBusy else { return }

        guard let myUserId = authService.currentUserId,
              let peerId = conversation.otherParticipant(myUserId: myUserId) else { return }

        let fresh = (try? conversationRepository.fetch(id: conversation.id, ownerUserId: myUserId)) ?? conversation
        guard fresh.relationshipState.allowsSending else {
            errorMessage = "You can call someone once they've accepted your invitation."
            return
        }

        guard await requestPermissions(video: video) else {
            errorMessage = video
                ? "Camera and microphone access are needed for video calls. Enable them in Settings."
                : "Microphone access is needed for calls. Enable it in Settings."
            return
        }

        let callId = UUID().uuidString
        activeConversation = fresh
        activePeerId = peerId
        isVideoCall = video
        isVideoEnabled = video
        isSpeakerOn = video
        phase = .outgoing(callId: callId, isVideo: video)

        #if canImport(WebRTC)
        do {
            let connection = try makePeerConnection(video: video)
            peerConnection = connection
            try attachLocalMedia(to: connection, video: video)

            let offer = try await connection.offer(for: mediaConstraints(video: video))
            try await connection.setLocalDescription(offer)

            try await sendHandler?(
                .offer(CallOffer(callId: callId, sdp: offer.sdp, isVideo: video, startedAt: Date())),
                fresh
            )
            startRingTimeout()
        } catch {
            logger.error("Couldn't start the call: \(String(describing: error), privacy: .public)")
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
            errorMessage = "Microphone access is needed to answer. Enable it in Settings."
            await endCall(reason: .declined)
            return
        }

        ringTimeoutTask?.cancel()
        phase = .connecting(callId: callId)
        isVideoCall = isVideo
        isVideoEnabled = isVideo
        isSpeakerOn = isVideo

        #if canImport(WebRTC)
        do {
            guard let connection = peerConnection else { return }
            try configureAudioSession(video: isVideo)
            try attachLocalMedia(to: connection, video: isVideo)

            let answer = try await connection.answer(for: mediaConstraints(video: isVideo))
            try await connection.setLocalDescription(answer)

            try await sendHandler?(
                .answer(CallAnswer(callId: callId, sdp: answer.sdp, isVideo: isVideo)),
                conversation
            )
            startConnectTimeout()
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
        guard phase.isBusy else { return }
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

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
    }

    func toggleVideo() async {
        #if canImport(WebRTC)
        guard isVideoCall, let track = localVideoTrack else {
            errorMessage = "Video can't be added to a voice call yet. Start a video call instead."
            return
        }
        isVideoEnabled.toggle()
        // While the screen is being shared the track carries the screen, so it
        // stays on; the camera setting applies again when sharing stops.
        if !isScreenSharing {
            track.isEnabled = isVideoEnabled
            if isVideoEnabled { startCameraCapture() } else { await stopCameraCapture() }
        }
        await broadcastState()
        #endif
    }

    // MARK: Screen sharing

    /// Why screen sharing can't start right now, or nil if it can.
    var screenShareUnavailableReason: String? {
        if !isAvailable { return "Calling isn't available in this build." }
        if !ScreenShareCoordinator.isExtensionConfigured {
            return "Screen sharing needs the HyperChat Screen Share extension, which isn't in this build."
        }
        if !isVideoCall { return "Screen sharing works in video calls. Start a video call to share your screen." }
        return nil
    }

    /// The broadcast itself is started from the system picker (see
    /// `ScreenShareButton`); this only reports why it can't be used.
    func toggleScreenShare() async {
        if let reason = screenShareUnavailableReason { errorMessage = reason }
    }

    #if canImport(WebRTC)
    private func startScreenShareListener() {
        guard ScreenShareCoordinator.isExtensionConfigured,
              let source = localVideoSource else { return }
        let capturer = RTCVideoCapturer(delegate: source)
        screenCapturer = capturer

        screenReceiver.start(
            onFrame: { pixelBuffer, degrees, timestamp in
                let rotation: RTCVideoRotation
                switch degrees {
                case 90: rotation = ._90
                case 180: rotation = ._180
                case 270: rotation = ._270
                default: rotation = ._0
                }
                let frame = RTCVideoFrame(
                    buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                    rotation: rotation,
                    timeStampNs: timestamp
                )
                source.capturer(capturer, didCapture: frame)
            },
            onState: { [weak self] sharing in
                Task { @MainActor in await self?.screenShareStateChanged(sharing) }
            }
        )
    }
    #endif

    private func screenShareStateChanged(_ sharing: Bool) async {
        #if canImport(WebRTC)
        guard isVideoCall, sharing != isScreenSharing else { return }
        isScreenSharing = sharing
        if sharing {
            await stopCameraCapture()
            localVideoTrack?.isEnabled = true
        } else {
            localVideoTrack?.isEnabled = isVideoEnabled
            if isVideoEnabled { startCameraCapture() }
        }
        await broadcastState()
        #endif
    }

    private func broadcastState() async {
        guard let conversation = activeConversation, let callId = currentCallId else { return }
        try? await sendHandler?(
            .update(CallStateUpdate(
                callId: callId,
                isAudioMuted: isAudioMuted,
                isVideoEnabled: isVideoEnabled || isScreenSharing,
                isScreenSharing: isScreenSharing
            )),
            conversation
        )
    }

    // MARK: Incoming signals

    func handle(_ signal: CallSignal, from peerId: String, conversation: Conversation) async {
        if let current = currentCallId {
            if signal.callId != current {
                if case .offer(let offer) = signal, Self.isFresh(offer) {
                    try? await sendHandler?(.end(CallEnd(callId: signal.callId, reason: .busy)), conversation)
                }
                return
            }
            if let activePeerId, activePeerId != peerId { return }
        } else {
            switch signal {
            case .offer, .candidate: break
            case .answer, .end, .update: return
            }
        }

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

    private static func isFresh(_ offer: CallOffer) -> Bool {
        Date().timeIntervalSince(offer.startedAt) < CallLimits.ringTimeout + 15
    }

    private func receiveOffer(_ offer: CallOffer, from peerId: String, conversation: Conversation) async {
        guard Self.isFresh(offer) else {
            logger.info("Ignoring a stale call offer")
            return
        }
        guard conversation.relationshipState.allowsSending else {
            logger.info("Ignoring a call from someone whose invitation isn't accepted")
            return
        }
        guard !phase.isBusy else {
            try? await sendHandler?(.end(CallEnd(callId: offer.callId, reason: .busy)), conversation)
            return
        }

        activeConversation = conversation
        activePeerId = peerId
        phase = .incoming(callId: offer.callId, isVideo: offer.isVideo, peerId: peerId)
        remoteIsVideoEnabled = offer.isVideo
        isVideoCall = offer.isVideo

        #if canImport(WebRTC)
        do {
            let connection = try makePeerConnection(video: offer.isVideo)
            peerConnection = connection
            try await connection.setRemoteDescription(
                RTCSessionDescription(type: .offer, sdp: offer.sdp)
            )
            await flushPendingCandidates(callId: offer.callId)
        } catch {
            logger.error("Couldn't accept the incoming offer")
            await endCall(reason: .failed)
            return
        }
        #endif

        startRingTimeout()
    }

    private func receiveAnswer(_ answer: CallAnswer) async {
        #if canImport(WebRTC)
        guard let connection = peerConnection else { return }
        do {
            try await connection.setRemoteDescription(
                RTCSessionDescription(type: .answer, sdp: answer.sdp)
            )
            await flushPendingCandidates(callId: answer.callId)
            remoteIsVideoEnabled = answer.isVideo
            phase = .connecting(callId: answer.callId)
            ringTimeoutTask?.cancel()
            startConnectTimeout()
        } catch {
            logger.error("Couldn't apply the answer")
            await endCall(reason: .failed)
        }
        #endif
    }

    private func receiveCandidate(_ candidate: IceCandidate) async {
        #if canImport(WebRTC)
        guard let connection = peerConnection, connection.remoteDescription != nil else {
            pendingRemoteCandidates.append(candidate)
            return
        }
        try? await connection.add(
            RTCIceCandidate(sdp: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        )
        #endif
    }

    private func flushPendingCandidates(callId: String) async {
        #if canImport(WebRTC)
        guard let connection = peerConnection else { return }
        for candidate in pendingRemoteCandidates where candidate.callId == callId {
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
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        screenReceiver.stop()

        #if canImport(WebRTC)
        let capturer = videoCapturer
        capturer?.stopCapture()
        videoCapturer = nil
        screenCapturer = nil
        localVideoSource = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        #endif

        pendingRemoteCandidates.removeAll()
        activeConversation = nil
        isAudioMuted = false
        isVideoEnabled = false
        isVideoCall = false
        isSpeakerOn = false
        isScreenSharing = false
        remoteIsScreenSharing = false
        remoteIsVideoEnabled = false
        connectedAt = nil
        phase = .ended(reason: reason)

        Task {
            try? await Task.sleep(for: .seconds(2))
            if case .ended = self.phase {
                self.phase = .idle
                self.activePeerId = nil
            }
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startRingTimeout() {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CallLimits.ringTimeout))
            guard !Task.isCancelled else { return }
            await self?.endCall(reason: .unanswered)
        }
    }

    private func startConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CallLimits.connectTimeout))
            guard !Task.isCancelled, let self else { return }
            if case .active = self.phase { return }
            self.errorMessage = "The call couldn't connect. One of you may be on a network that blocks direct connections."
            await self.endCall(reason: .failed)
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
        try session.setCategory(
            .playAndRecord,
            mode: video ? .videoChat : .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true)
    }

    #if canImport(WebRTC)
    private func mediaConstraints(video: Bool) -> RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": video ? "true" : "false",
            ],
            optionalConstraints: nil
        )
    }

    private func makePeerConnection(video: Bool) throws -> RTCPeerConnection {
        try configureAudioSession(video: video)

        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302",
        ])]
        config.sdpSemantics = .unifiedPlan
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
        localVideoSource = videoSource
        videoCapturer = capturer
        startCameraCapture()
        startScreenShareListener()
    }

    private func startCameraCapture() {
        guard let capturer = videoCapturer,
              let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
        else { return }

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
    #else
    private func stopCameraCapture() async {}
    #endif
}

#if canImport(WebRTC)
extension CallService: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let sdp = candidate.sdp
        let index = candidate.sdpMLineIndex
        let mid = candidate.sdpMid
        Task { @MainActor in
            guard let conversation = self.activeConversation, let callId = self.currentCallId else { return }
            try? await self.sendHandler?(
                .candidate(IceCandidate(callId: callId, sdp: sdp, sdpMLineIndex: index, sdpMid: mid)),
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
                self.connectTimeoutTask?.cancel()
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(self.isSpeakerOn ? .speaker : .none)
            case .failed:
                await self.endCall(reason: .failed)
            case .disconnected:
                break
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor in self.remoteVideoTrack = track }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard let track = stream.videoTracks.first else { return }
        Task { @MainActor in
            if self.remoteVideoTrack == nil { self.remoteVideoTrack = track }
        }
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
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

/// Finds the screen-share extension inside the app bundle.
///
/// FIX: the old check looked for an App Group container, which never exists
/// for a sideloaded free-account build — so screen sharing always reported
/// "isn't set up". The extension now talks to the app over 127.0.0.1 and
/// needs no App Group.
enum ScreenShareCoordinator {
    static let extensionName = "HyperChatScreenShare"

    static var extensionBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.HyperChat.app") + "." + extensionName
    }

    static var isExtensionConfigured: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        let url = plugins.appendingPathComponent(extensionName + ".appex")
        return FileManager.default.fileExists(atPath: url.path)
    }
}
