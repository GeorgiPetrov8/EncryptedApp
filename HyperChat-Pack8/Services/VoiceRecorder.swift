import Foundation
import AVFoundation
import Combine
import os

/// Records voice messages (feature: audio messages).
///
/// Records to AAC in an m4a container, which is hardware-encoded on iOS and
/// plays natively everywhere. A voice message is a throwaway artefact, so the
/// settings favour small files over fidelity: mono, 24 kHz, 32 kbps — roughly
/// 240 KB per minute, against ~1.4 MB for the same minute at 128 kbps stereo.
/// Speech loses nothing audible at those settings.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    /// Normalised 0…1, for the waveform. Updated at 20 Hz — fast enough to look
    /// live, slow enough not to wake the CPU constantly during a long recording.
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?
    private let logger = Logger(subsystem: "com.HyperChat", category: "voice")

    /// Beyond this a voice message stops being a message. Also bounds the
    /// upload size and the recipient's patience.
    static let maxDuration: TimeInterval = 5 * 60

    /// Below this it's almost certainly a mis-tap on the mic button rather
    /// than something the user meant to send.
    static let minDuration: TimeInterval = 0.6

    // MARK: Permission

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            // `AVAudioApplication` replaced `AVAudioSession.requestRecordPermission`
            // in iOS 17; the deployment target is 17.0 so the old spelling is
            // unnecessary.
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
        // `.playAndRecord` rather than `.record` so playback of an existing
        // message doesn't have to tear down and rebuild the session.
        // `.defaultToSpeaker` because without it iOS routes to the earpiece,
        // and the user hears nothing on playback while wondering why.
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        recorder.record(forDuration: Self.maxDuration)

        self.recorder = recorder
        self.fileURL = url
        isRecording = true
        duration = 0
        startMetering()
    }

    /// Stops and returns the recording, or `nil` if it was too short to be
    /// intentional.
    func stop() -> RecordedVoiceMessage? {
        guard let recorder, isRecording else { return nil }

        let recordedDuration = recorder.currentTime
        recorder.stop()
        stopMetering()
        isRecording = false
        self.recorder = nil

        // Deactivated so music or a podcast that was ducked resumes.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = fileURL else { return nil }

        guard recordedDuration >= Self.minDuration else {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
            return nil
        }

        guard let data = try? Data(contentsOf: url) else { return nil }
        // Read into memory, then delete immediately: the temporary directory
        // has no file-protection class, so an unencrypted voice recording
        // should live there for as little time as possible.
        try? FileManager.default.removeItem(at: url)
        fileURL = nil

        return RecordedVoiceMessage(
            data: data,
            duration: recordedDuration,
            waveform: capturedWaveform
        )
    }

    /// Abandons the recording — the swipe-to-cancel gesture.
    func cancel() {
        recorder?.stop()
        stopMetering()
        isRecording = false
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        capturedWaveform = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Metering

    /// Sampled amplitudes, downsampled to a fixed bar count when sent so the
    /// recipient can draw the same waveform without decoding the audio.
    private var capturedWaveform: [Float] = []

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
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        duration = recorder.currentTime

        // `averagePower` is in dBFS, roughly -160 (silence) to 0 (clipping).
        // Speech sits around -40…-10, so a linear map over the full range would
        // leave the waveform nearly flat. Clamping to -50 and normalising gives
        // a visible signal.
        let db = recorder.averagePower(forChannel: 0)
        let normalised = max(0, (db + 50) / 50)
        level = normalised
        capturedWaveform.append(normalised)
    }
}

extension VoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Fires when `forDuration:` elapses. The UI observes `isRecording`, so
        // hitting the cap ends the recording rather than silently continuing
        // to show a running timer.
        Task { @MainActor in
            guard self.isRecording else { return }
            self.isRecording = false
            self.stopMetering()
        }
    }
}

struct RecordedVoiceMessage {
    let data: Data
    let duration: TimeInterval
    let waveform: [Float]

    /// Downsamples to a fixed bar count for transmission.
    ///
    /// Sent alongside the audio so the recipient renders the waveform
    /// instantly, without downloading and decoding the file first — which
    /// matters because the point of a waveform is to decide whether to listen.
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
