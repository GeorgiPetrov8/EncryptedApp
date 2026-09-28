import SwiftUI
import AVFoundation

/// Hold-to-record control in the composer.
///
/// Press and hold to record, release to send, slide left to cancel — the
/// gesture people already know. A tap-to-start/tap-to-stop toggle is easier to
/// build but leaves a recording running when the user gets distracted, which
/// is how you accidentally send ninety seconds of ambient noise.
struct VoiceRecordButton: View {
    @ObservedObject var recorder: VoiceRecorder
    let isDisabled: Bool
    let onFinished: (RecordedVoiceMessage) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var permissionDenied = false

    /// Past this leftward distance, releasing cancels instead of sending.
    private let cancelThreshold: CGFloat = -80

    var body: some View {
        Image(systemName: recorder.isRecording ? "mic.fill" : "mic")
            .font(.title2)
            .foregroundStyle(iconColor)
            .scaleEffect(recorder.isRecording ? 1.3 : 1.0)
            .animation(.spring(duration: 0.2), value: recorder.isRecording)
            .offset(x: min(0, dragOffset))
            .gesture(recordGesture)
            .disabled(isDisabled)
            .accessibilityLabel("Hold to record a voice message")
            .alert("Microphone access needed", isPresented: $permissionDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Voice messages need permission to use the microphone.")
            }
    }

    private var iconColor: Color {
        if isDisabled { return .secondary }
        if dragOffset < cancelThreshold { return .red }
        return recorder.isRecording ? .red : .accentColor
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !recorder.isRecording {
                    Task { await beginRecording() }
                }
                dragOffset = value.translation.width
            }
            .onEnded { _ in
                let cancelled = dragOffset < cancelThreshold
                dragOffset = 0
                if cancelled {
                    recorder.cancel()
                } else if let recorded = recorder.stop() {
                    onFinished(recorded)
                }
                // A too-short recording returns nil from `stop()` and is
                // silently discarded — a mis-tap shouldn't send anything, and
                // shouldn't produce an error either.
            }
    }

    private func beginRecording() async {
        switch recorder.permissionStatus {
        case .granted:
            try? recorder.start()
        case .denied:
            permissionDenied = true
        default:
            if await recorder.requestPermission() {
                try? recorder.start()
            } else {
                permissionDenied = true
            }
        }
    }
}

/// The recording indicator that replaces the text field while recording.
struct VoiceRecordingBar: View {
    @ObservedObject var recorder: VoiceRecorder

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(recorder.isRecording ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: recorder.isRecording)

            Text(timeString(recorder.duration))
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()

            LiveWaveform(level: recorder.level)

            Spacer()

            Label("Slide to cancel", systemImage: "chevron.left")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func timeString(_ interval: TimeInterval) -> String {
        String(format: "%d:%02d", Int(interval) / 60, Int(interval) % 60)
    }
}

/// Live level meter during recording.
private struct LiveWaveform: View {
    let level: Float
    @State private var history: [Float] = Array(repeating: 0, count: 24)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: max(3, CGFloat(history[index]) * 22))
            }
        }
        .onChange(of: level) { _, newValue in
            history.removeFirst()
            history.append(newValue)
        }
    }
}

/// Playback bubble for a received or sent voice message.
struct VoiceMessageBubble: View {
    let duration: TimeInterval
    let waveform: [Float]
    let audioData: () async -> Data?
    var tint: Color = .accentColor

    @StateObject private var player = VoiceMessagePlayer()

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task { await togglePlayback() }
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play voice message")

            VStack(alignment: .leading, spacing: 4) {
                StaticWaveform(samples: waveform, progress: player.progress, tint: tint)
                    .frame(height: 24)
                Text(timeString(player.isPlaying ? player.currentTime : duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 200)
    }

    private func togglePlayback() async {
        if player.isPlaying {
            player.pause()
        } else if let data = await audioData() {
            player.play(data: data)
        }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        String(format: "%d:%02d", Int(interval) / 60, Int(interval) % 60)
    }
}

/// The transmitted waveform, with the played portion highlighted.
private struct StaticWaveform: View {
    let samples: [Float]
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(samples.indices, id: \.self) { index in
                    let played = Double(index) / Double(max(samples.count - 1, 1)) <= progress
                    Capsule()
                        .fill(played ? tint : tint.opacity(0.3))
                        .frame(height: max(3, CGFloat(samples[index]) * geometry.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

@MainActor
final class VoiceMessagePlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentTime: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(data: Data) {
        do {
            // `.playback` so a voice message is audible with the ringer switch
            // set to silent — otherwise the common case is tapping play and
            // hearing nothing with no explanation.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)

            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.play()
            self.player = player
            isPlaying = true
            startTimer()
        } catch {
            isPlaying = false
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension VoiceMessagePlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = 0
            self.currentTime = 0
            self.stopTimer()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
