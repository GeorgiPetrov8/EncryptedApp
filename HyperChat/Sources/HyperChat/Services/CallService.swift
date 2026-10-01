import Foundation
import Combine
import AVFoundation
import os

#if canImport(WebRTC)
import WebRTC
#endif

/// Orchestrates calls: signalling over the encrypted channel, media over WebRTC.
///
/// Needs the `stasel/WebRTC` Swift package. Guarded by `#if canImport(WebRTC)`
/// so the project still builds without it — the call buttons then say calling
/// isn't available.
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
    /// FIX: published so `CallView` can show who's calling.
    @Published private(set) var activePeerId: String?
    /// Whether this call was started as a video call. Video can't be added to
    /// an audio call mid-way (that needs SDP renegotiation, not implemented).
    @Published private(set) var isVideoCall = false

    #if canImport(WebRTC)
    /// FIX: the tracks are exposed so the video views can actually render
    /// them. The previous `RTCVideoView` was never attached to any track, so
    /// video calls showed a black screen on both sides.
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

    #if canImport(WebRTC)
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var videoCapturer: RTCCameraVideoCapturer?

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

    /// Returns and clears the last error, for callers that show it themselves.
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

        // FIX: re-enabled. Calling someone who hasn't accepted an invitation
        // would bypass the gate the invitation feature exists to provide.
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

        // FIX: the ring timeout used to keep running after answering. If ICE
        // took longer than the remaining ring time, an answered call was hung
        // up as "unanswered". Now ringing stops and a connect timeout starts.
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
        // Cancelling our own unanswered call is "hang up" from our side; the
        // other side shows it as a missed call.
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

    /// Turns the camera off/on *within* a video call.
    ///
    /// FIX: on an audio call there is no video track, so this used to flip the
    /// "camera on" flag while nothing was being sent. Adding video to an audio
    /// call needs renegotiation; until that exists the UI hides the button.
    func toggleVideo() async {
        #if canImport(WebRTC)
        guard isVideoCall, let track = localVideoTrack else {
            errorMessage = "Video can't be added to a voice call yet. Start a video call instead."
            return
        }
        isVideoEnabled.toggle()
        track.isEnabled = isVideoEnabled
        if isVideoEnabled { startCameraCapture() } else { await stopCameraCapture() }
        await broadcastState()
        #endif
    }

    /// Screen sharing needs a Broadcast Upload Extension target — iOS doesn't
    /// let an app capture the screen from its own process. Until that target
    /// exists this reports the reason instead of silently doing nothing.
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

    // MARK: Incoming signals

    func handle(_ signal: CallSignal, from peerId: String, conversation: Conversation) async {
        if let current = currentCallId {
            if signal.callId != current {
                // A new offer while we're busy gets "busy"; any other signal
                // from a different call is stale and ignored.
                if case .offer(let offer) = signal, Self.isFresh(offer) {
                    try? await sendHandler?(.end(CallEnd(callId: signal.callId, reason: .busy)), conversation)
                }
                return
            }
            // Only the person we're on a call with may control it.
            if let activePeerId, activePeerId != peerId { return }
        } else {
            // FIX: no call in progress. Only an offer (or an early ICE
            // candidate that overtook its offer) is meaningful. A late "end" or
            // "update" from a finished call used to flash a "Call ended" screen.
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

    /// FIX: an offer that waited in the offline queue must not ring.
    ///
    /// Signals travel through the same durable queue as messages, so an offer
    /// sent while you were offline is delivered when you next open the app —
    /// possibly hours later — and the phone would ring for a call the caller
    /// gave up on long ago. The allowance on top of the ring timeout absorbs
    /// clock differences between the two phones.
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
        // Set before the remote description, so early candidates for this
        // call are accepted and stale ones from other calls dropped.
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
            // Arrived before the description it belongs to — buffer it.
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
        // FIX: only this call's candidates; buffered leftovers from another
        // call are discarded instead of being fed into this connection.
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

        #if canImport(WebRTC)
        let capturer = videoCapturer
        capturer?.stopCapture()
        videoCapturer = nil
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

        // Back to idle after a moment, so the UI can show why it ended.
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

    /// FIX: without this a call whose media never connects sat on
    /// "Connecting…" forever. With no TURN server that's not rare — strict
    /// NATs and some mobile networks can't connect peer-to-peer.
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
        // `.videoChat` prefers the speaker; `.voiceChat` keeps the earpiece.
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
        // STUN only. Roughly 10–20% of connections (symmetric NAT, strict
        // corporate/mobile networks) need a TURN relay to connect. Add one here
        // when you have it:
        //   RTCIceServer(urlStrings: ["turn:turn.example.com:3478"],
        //                username: "...", credential: "...")
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
        videoCapturer = capturer
        startCameraCapture()
    }

    private func startCameraCapture() {
        guard let capturer = videoCapturer,
              let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
        else { return }

        // ~640 px wide at up to 30 fps: enough for a call, light on battery.
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
                // Applied after connecting: WebRTC reconfigures the audio
                // route while connecting and would undo an earlier override.
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(self.isSpeakerOn ? .speaker : .none)
            case .failed:
                await self.endCall(reason: .failed)
            case .disconnected:
                // Not terminal: ICE recovers from brief network changes.
                break
            default:
                break
            }
        }
    }

    /// FIX: where the remote video actually arrives (Unified Plan). This
    /// callback was missing, so there was never a remote track to render.
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor in self.remoteVideoTrack = track }
    }

    /// Plan-B fallback for older peers.
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

/// Boundary for the Broadcast Upload Extension that screen sharing requires.
enum ScreenShareCoordinator {
    static let appGroupIdentifier = "group.com.hyperchat.broadcast"

    static var isExtensionConfigured: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil
    }
}
