import Foundation
import AVFoundation
import Combine
import os

/// Records voice messages: AAC/m4a, mono, 24 kHz, 32 kbps (~240 KB per minute).
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var isLocked = false
    @Published private(set) var isPaused = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0

    /// FIX (waveform froze in silence): the last 24 levels, republished on
    /// every 50 ms tick. The old view only redrew when `level` *changed* —
    /// in silence the level stays at 0, so nothing changed and the bars froze
    /// until a sound arrived. A new array every tick keeps them moving.
    @Published private(set) var recentLevels: [Float] = Array(repeating: 0, count: VoiceRecorder.visibleBars)

    static let visibleBars = 24

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?
    private var capturedWaveform: [Float] = []
    private let logger = Logger(subsystem: "com.HyperChat", category: "voice")

    static let maxDuration: TimeInterval = 5 * 60
    static let minDuration: TimeInterval = 0.6

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

    func start() throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw VoiceRecorderError.couldNotStart }

        self.recorder = recorder
        self.fileURL = url
        capturedWaveform = []
        recentLevels = Array(repeating: 0, count: Self.visibleBars)
        duration = 0
        isPaused = false
        isLocked = false
        isRecording = true
        startMetering()
    }

    func lock() {
        guard isRecording else { return }
        isLocked = true
    }

    func pause() {
        guard isRecording, !isPaused, let recorder else { return }
        duration = recorder.currentTime
        recorder.pause()
        isPaused = true
        level = 0
    }

    func resume() {
        guard isRecording, isPaused, let recorder, duration < Self.maxDuration else { return }
        recorder.record()
        isPaused = false
    }

    func stop() -> RecordedVoiceMessage? {
        guard let recorder, isRecording else { return nil }

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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Metering

    private func startMetering() {
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
