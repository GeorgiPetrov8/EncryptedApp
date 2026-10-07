import Foundation
import AVFoundation
import Combine
import os

/// Configures the shared audio session off the main thread.
///
/// FIX (UI froze for a moment when recording / playing started): switching
/// the audio session (`setCategory` + `setActive`) talks to the system audio
/// server and can block for a few hundred milliseconds — the first time, and
/// whenever the route changes between playback and recording. It used to run
/// on the main thread inside the button gesture, so animations stalled as if
/// the app was about to crash. All session work now runs on this queue.
enum AudioSessionQueue {
    static let queue = DispatchQueue(label: "com.hyperchat.audiosession", qos: .userInitiated)

    static func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Records voice messages: AAC/m4a, mono, 24 kHz, 32 kbps (~240 KB per minute).
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var isLocked = false
    @Published private(set) var isPaused = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var recentLevels: [Float] = Array(repeating: 0, count: VoiceRecorder.visibleBars)

    static let visibleBars = 24
    static let maxDuration: TimeInterval = 5 * 60
    static let minDuration: TimeInterval = 0.6

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?
    private var capturedWaveform: [Float] = []
    /// Bumped on every start/cancel, so a slow start that finishes after the
    /// user already let go is thrown away instead of recording on its own.
    private var generation = 0
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

    // MARK: Recording

    /// Shows the recording UI immediately; the microphone starts a moment
    /// later, once the audio session is ready (off the main thread).
    func start() {
        guard !isRecording else { return }
        generation += 1
        let token = generation

        isRecording = true
        isPaused = false
        isLocked = false
        duration = 0
        capturedWaveform = []
        recentLevels = Array(repeating: 0, count: Self.visibleBars)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        fileURL = url

        Task {
            do {
                let recorder = try await AudioSessionQueue.run { () -> AVAudioRecorder in
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
                    try session.setActive(true)
                    let recorder = try AVAudioRecorder(url: url, settings: [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 24_000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 32_000,
                        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                    ])
                    recorder.isMeteringEnabled = true
                    recorder.prepareToRecord()
                    return recorder
                }
                guard token == generation, isRecording else {
                    // Released or cancelled while the session was starting.
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                guard recorder.record() else { throw VoiceRecorderError.couldNotStart }
                self.recorder = recorder
                if isPaused { recorder.pause() }
                startMetering()
            } catch {
                logger.error("Couldn't start recording")
                guard token == generation else { return }
                finishSession()
            }
        }
    }

    func lock() {
        guard isRecording else { return }
        isLocked = true
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        if let recorder {
            duration = recorder.currentTime
            recorder.pause()
        }
        isPaused = true
        level = 0
    }

    func resume() {
        guard isRecording, isPaused, duration < Self.maxDuration else { return }
        recorder?.record()
        isPaused = false
    }

    /// Stops and returns the recording, or `nil` if it was too short (or the
    /// microphone hadn't even started yet).
    func stop() -> RecordedVoiceMessage? {
        guard isRecording else { return nil }
        generation += 1

        guard let recorder else {
            // Let go before the microphone was ready: nothing recorded.
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            fileURL = nil
            finishSession()
            return nil
        }

        let recordedDuration = isPaused ? duration : max(duration, recorder.currentTime)
        recorder.stop()
        finishSession()

        guard let url = fileURL else { return nil }
        defer {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
        }
        guard recordedDuration >= Self.minDuration, let data = try? Data(contentsOf: url) else { return nil }
        return RecordedVoiceMessage(data: data, duration: recordedDuration, waveform: capturedWaveform)
    }

    func cancel() {
        generation += 1
        recorder?.stop()
        finishSession()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        capturedWaveform = []
    }

    private func finishSession() {
        stopMetering()
        recorder = nil
        isRecording = false
        isLocked = false
        isPaused = false
        AudioSessionQueue.deactivate()
    }

    // MARK: Metering

    private func startMetering() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMetering() }
        }
    }

    private func stopMetering() {
        timer?.invalidate()
        timer = nil
        level = 0
    }

    private func updateMetering() {
        guard let recorder, isRecording, !isPaused, recorder.isRecording else { return }
        recorder.updateMeters()
        duration = recorder.currentTime

        let db = recorder.averagePower(forChannel: 0)
        let normalised = max(0, (db + 50) / 50)
        level = normalised
        capturedWaveform.append(normalised)

        var levels = recentLevels
        levels.removeFirst()
        levels.append(normalised)
        recentLevels = levels

        if duration >= Self.maxDuration {
            pause()
            isLocked = true
        }
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
