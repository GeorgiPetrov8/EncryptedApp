import Foundation
import AVFoundation
import Combine
import UIKit
import os

/// Records voice messages as AAC/m4a, mono.
///
/// WHY THIS WAS REWRITTEN. The recording UI started the moment the finger touched the
/// mic, but the microphone itself needs a moment to come up: the audio session has to
/// switch category and activate, the route may have to change (Bluetooth), and the
/// hardware has to start delivering samples. All of that happens *after* the button
/// press, so the first stretch of speech was never captured while the waveform
/// already moved.
///
/// Two changes:
///   1. Capture is done with `AVAudioEngine` and an input tap, so there is an exact
///      "audio is really arriving" moment — `isCapturing` — instead of guessing.
///      The timer, the waveform and the stored waveform start from *that* moment.
///   2. The session switch runs on a background queue (it can block for hundreds of
///      milliseconds and used to freeze the interface), and recording that is stopped
///      before capture began is discarded cleanly instead of racing the setup.
///
/// The UI shows "Starting…" until `isCapturing` turns true, so what you see matches
/// what is recorded. Hardware start-up can't be made zero, only made visible.
///
/// Two ways to record:
///   - hold the mic and release to send;
///   - tap the mic (or slide up while holding) to lock: hands-free, with delete,
///     pause/resume and an explicit Send.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {

    /// The user asked to record (the UI is in recording mode).
    @Published private(set) var isRecording = false
    /// Audio is actually being captured. False for the first moments after `start()`.
    @Published private(set) var isCapturing = false
    @Published private(set) var isLocked = false
    @Published private(set) var isPaused = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0
    /// Set when recording couldn't start; the recorder has already reset itself.
    @Published private(set) var lastError: String?

    static let maxDuration: TimeInterval = 5 * 60
    /// Shorter than this is a mis-tap, not a message.
    static let minDuration: TimeInterval = 0.6
    /// If no audio arrives within this long, give up instead of hanging on "Starting…".
    private static let startTimeout: TimeInterval = 3

    private var capture: CaptureSession?
    private var timer: Timer?
    private var requestedAt = Date()
    private var capturedWaveform: [Float] = []

    /// Serial, so a `stop()` followed straight away by a `start()` can't interleave.
    private let sessionQueue = DispatchQueue(label: "com.HyperChat.voice.session", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.HyperChat", category: "voice")

    // MARK: Permission

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    var permissionStatus: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    // MARK: Start

    /// Returns immediately; capture begins asynchronously (see `isCapturing`).
    func start() throws {
        guard !isRecording else { return }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let session = CaptureSession(url: url)
        session.onFirstBuffer = { [weak self, weak session] in
            guard let session else { return }
            Task { @MainActor in self?.captureDidStart(session) }
        }

        capture = session
        capturedWaveform = []
        duration = 0
        level = 0
        lastError = nil
        requestedAt = Date()
        isPaused = false
        isLocked = false
        isCapturing = false
        isRecording = true
        startTimer()

        sessionQueue.async { [weak self] in
            let audio = AVAudioSession.sharedInstance()
            do {
                try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                // Without this iOS suppresses haptics and system sounds while recording.
                try? audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
                try audio.setActive(true)
                try session.begin()
                // Released before capture began: begin() may have finished after the
                // cancel, so make sure nothing is left running.
                if session.isCancelled {
                    session.finish()
                    try? audio.setActive(false, options: .notifyOthersOnDeactivation)
                }
            } catch {
                session.finish()
                try? audio.setActive(false, options: .notifyOthersOnDeactivation)
                Task { @MainActor in self?.captureDidFail(session) }
            }
        }
    }

    private func captureDidStart(_ session: CaptureSession) {
        guard capture === session, !isCapturing else { return }
        isCapturing = true
        // The moment the user can start talking.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func captureDidFail(_ session: CaptureSession) {
        guard capture === session else { return }
        logger.error("Voice capture couldn't start")
        lastError = "Couldn't start recording."
        capture = nil
        resetState()
    }

    // MARK: Controls

    /// Hands-free mode: keeps recording after the finger lifts.
    func lock() {
        guard isRecording else { return }
        isLocked = true
    }

    func pause() {
        guard isRecording, isCapturing, !isPaused, let capture else { return }
        duration = capture.snapshot().duration
        capture.pause()
        isPaused = true
        level = 0
    }

    func resume() {
        guard isRecording, isPaused, duration < Self.maxDuration, let capture else { return }
        if capture.resume() { isPaused = false }
    }

    /// Stops and returns the recording, or `nil` if it was too short or never began.
    func stop() -> RecordedVoiceMessage? {
        guard isRecording, let capture else { return nil }
        let wasCapturing = isCapturing
        let waveform = capturedWaveform
        self.capture = nil
        resetState()

        guard wasCapturing else {
            // Released before audio started arriving: nothing worth keeping.
            capture.finish()
            discard(capture.url)
            deactivateSession()
            return nil
        }

        let recordedDuration = capture.finish()
        deactivateSession()
        defer { discard(capture.url) }

        guard recordedDuration >= Self.minDuration,
              let data = try? Data(contentsOf: capture.url) else { return nil }
        return RecordedVoiceMessage(data: data, duration: recordedDuration, waveform: waveform)
    }

    func cancel() {
        guard let capture else { return }
        self.capture = nil
        resetState()
        capture.finish()
        discard(capture.url)
        deactivateSession()
    }

    private func resetState() {
        stopTimer()
        isRecording = false
        isCapturing = false
        isLocked = false
        isPaused = false
        level = 0
    }

    /// The temporary directory has no file-protection class: keep the unencrypted
    /// recording on disk for as short a time as possible.
    private func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func deactivateSession() {
        sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Timer

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // `.common`, so it keeps firing while a finger is held on the mic button.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isRecording, let capture else { return }

        guard isCapturing else {
            if Date().timeIntervalSince(requestedAt) > Self.startTimeout {
                capture.finish()
                discard(capture.url)
                deactivateSession()
                captureDidFail(capture)
            }
            return
        }
        guard !isPaused else { return }

        let snapshot = capture.snapshot()
        duration = snapshot.duration
        level = snapshot.level
        capturedWaveform.append(snapshot.level)

        // At the cap: pause rather than stop, and lock, so the user still gets to
        // press Send instead of the recording silently disappearing.
        if duration >= Self.maxDuration {
            pause()
            isLocked = true
        }
    }
}

// MARK: - Capture

/// One recording: an `AVAudioEngine` input tap writing AAC to a file.
///
/// Lives off the main actor — the tap runs on the real-time audio thread — and is
/// guarded by two locks: `lock` for the state below, `writeLock` so the file isn't
/// finalised in the middle of a write.
private final class CaptureSession: @unchecked Sendable {
    let url: URL
    var onFirstBuffer: (@Sendable () -> Void)?

    private let lock = NSLock()
    private let writeLock = NSLock()
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var monoFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var level: Float = 0
    private var paused = false
    private var cancelled = false
    private var gotFirstBuffer = false

    init(url: URL) {
        self.url = url
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Starts the engine. Throws if the microphone can't be opened.
    func begin() throws {
        guard !isCancelled else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardware.sampleRate,
                channels: 1,
                interleaved: false
              ) else { throw VoiceRecorderError.couldNotStart }

        var settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: hardware.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        // 32 kbps is only valid from 16 kHz up; narrowband Bluetooth is 8 kHz.
        if hardware.sampleRate >= 16_000 { settings[AVEncoderBitRateKey] = 32_000 }

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        lock.lock()
        if cancelled { lock.unlock(); return }
        self.engine = engine
        self.sampleRate = hardware.sampleRate
        self.monoFormat = mono
        lock.unlock()
        writeLock.lock(); self.file = file; writeLock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: hardware) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()

        // Cancelled while the engine was starting.
        if isCancelled {
            input.removeTap(onBus: 0)
            engine.stop()
            writeLock.lock(); self.file = nil; writeLock.unlock()
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.floatChannelData?[0] else { return }

        var sum: Float = 0
        for index in 0..<frames {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        let normalised = max(0, min(1, (decibels + 50) / 50))

        lock.lock()
        level = normalised
        let isFirst = !gotFirstBuffer
        gotFirstBuffer = true
        let callback = isFirst ? onFirstBuffer : nil
        let shouldWrite = !paused && !cancelled
        let format = monoFormat
        lock.unlock()

        callback?()
        guard shouldWrite, let format else { return }

        writeLock.lock()
        defer { writeLock.unlock() }
        guard let file,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData?[0] else { return }
        mono.frameLength = buffer.frameLength
        // Channel 0 only: a mono voice message doesn't need the rest.
        destination.update(from: channel, count: frames)

        guard (try? file.write(from: mono)) != nil else { return }
        lock.lock()
        framesWritten += AVAudioFramePosition(frames)
        lock.unlock()
    }

    func snapshot() -> (duration: TimeInterval, level: Float) {
        lock.lock(); defer { lock.unlock() }
        let seconds = sampleRate > 0 ? Double(framesWritten) / sampleRate : 0
        return (seconds, level)
    }

    func pause() {
        lock.lock()
        paused = true
        let engine = self.engine
        lock.unlock()
        // Pausing the engine releases the microphone, so the recording indicator goes
        // off while paused.
        engine?.pause()
    }

    @discardableResult
    func resume() -> Bool {
        lock.lock(); let engine = self.engine; lock.unlock()
        guard let engine else { return false }
        do {
            try engine.start()
        } catch {
            return false
        }
        lock.lock(); paused = false; lock.unlock()
        return true
    }

    /// Stops capturing and closes the file. Safe to call more than once, and while
    /// `begin()` is still running on another thread.
    @discardableResult
    func finish() -> TimeInterval {
        lock.lock()
        cancelled = true
        let engine = self.engine
        self.engine = nil
        lock.unlock()

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()

        // Releasing the file is what writes the AAC trailer.
        writeLock.lock()
        file = nil
        writeLock.unlock()

        return snapshot().duration
    }
}

enum VoiceRecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        "Couldn't start recording."
    }
}

struct RecordedVoiceMessage {
    let data: Data
    let duration: TimeInterval
    let waveform: [Float]

    func normalisedWaveform(bars: Int = 40) -> [Float] {
        guard !waveform.isEmpty else { return Array(repeating: 0, count: bars) }
        guard waveform.count > bars else {
            return waveform + Array(repeating: 0, count: bars - waveform.count)
        }
        let bucketSize = waveform.count / bars
        return (0..<bars).map { index in
            let start = index * bucketSize
            let end = min(start + bucketSize, waveform.count)
            let slice = waveform[start..<end]
            return slice.isEmpty ? 0 : slice.reduce(0, +) / Float(slice.count)
        }
    }
}
