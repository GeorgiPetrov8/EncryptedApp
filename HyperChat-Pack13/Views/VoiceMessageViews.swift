import SwiftUI
import AVFoundation

/// The mic button.
///
/// - Hold, then release → sends.
/// - Quick tap → locks (records hands-free, shows Send / Delete / Pause).
/// - While holding, slide up → locks; slide left → cancels.
struct VoiceRecordButton: View {
    @ObservedObject var recorder: VoiceRecorder
    let isDisabled: Bool
    let onFinished: (RecordedVoiceMessage) -> Void

    @State private var pressStartedAt: Date?
    @State private var translation: CGSize = .zero
    @State private var permissionDenied = false

    private let cancelThreshold: CGFloat = -80
    private let lockThreshold: CGFloat = -60
    private let tapDuration: TimeInterval = 0.35

    var body: some View {
        Image(systemName: recorder.isRecording ? "mic.fill" : "mic")
            .font(.title2)
            .foregroundStyle(iconStyle)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .scaleEffect(recorder.isRecording ? 1.35 : 1.0)
            .offset(x: min(0, translation.width), y: min(0, translation.height))
            .animation(.spring(duration: 0.2), value: recorder.isRecording)
            .gesture(recordGesture, including: isDisabled ? .none : .all)
            .opacity(isDisabled ? 0.4 : 1)
            .accessibilityLabel("Record a voice message")
            .accessibilityHint("Hold to record and release to send, or tap to record hands-free")
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

    /// Red while recording; otherwise the composer's readable tint.
    private var iconStyle: AnyShapeStyle {
        if translation.width < cancelThreshold || recorder.isRecording {
            return AnyShapeStyle(Color.red)
        }
        return AnyShapeStyle(.tint)
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStartedAt == nil {
                    pressStartedAt = Date()
                    begin()
                }
                translation = value.translation
                if recorder.isRecording, !recorder.isLocked, value.translation.height < lockThreshold {
                    recorder.lock()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            .onEnded { _ in
                let started = pressStartedAt
                let finalTranslation = translation
                pressStartedAt = nil
                translation = .zero

                guard recorder.isRecording, !recorder.isLocked else { return }

                if finalTranslation.width < cancelThreshold {
                    recorder.cancel()
                    return
                }
                if let started, Date().timeIntervalSince(started) < tapDuration {
                    recorder.lock()
                    return
                }
                if let recorded = recorder.stop() {
                    onFinished(recorded)
                }
            }
    }

    private func begin() {
        switch recorder.permissionStatus {
        case .granted:
            recorder.start()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .denied:
            permissionDenied = true
        default:
            Task {
                if await recorder.requestPermission() == false {
                    permissionDenied = true
                }
            }
        }
    }
}

/// Shown in place of the text field while recording.
struct VoiceRecordingBar: View {
    @ObservedObject var recorder: VoiceRecorder

    var body: some View {
        HStack(spacing: 10) {
            RecordingDot(isPaused: recorder.isPaused)

            Text(timeString(recorder.duration))
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()

            LiveWaveform(levels: recorder.recentLevels, isPaused: recorder.isPaused)

            Spacer(minLength: 4)

            if !recorder.isLocked {
                Text("← cancel · ↑ lock")
                    .font(.caption2)
                    .lineLimit(1)
            } else if recorder.isPaused {
                Text("Paused")
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func timeString(_ interval: TimeInterval) -> String {
        String(format: "%d:%02d", Int(interval) / 60, Int(interval) % 60)
    }
}

private struct RecordingDot: View {
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let pulse = isPaused ? 0.3 : 0.55 + 0.45 * abs(sin(phase * 3))
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .opacity(pulse)
        }
    }
}

/// Redraws from the recorder's rolling buffer; silent samples "breathe" so
/// the bars never freeze.
private struct LiveWaveform: View {
    let levels: [Float]
    let isPaused: Bool

    var body: some View {
        // 30 fps is plenty for this and halves the work of a 120 Hz screen.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(.red.opacity(0.8))
                        .frame(width: 2, height: barHeight(levels[index], index: index, phase: phase))
                }
            }
            .frame(height: 22)
        }
    }

    private func barHeight(_ level: Float, index: Int, phase: Double) -> CGFloat {
        let base = CGFloat(level) * 20
        guard base < 3 else { return base }
        let idle = isPaused ? 0 : 1.5 * abs(sin(phase * 4 + Double(index) * 0.5))
        return 3 + CGFloat(idle)
    }
}

/// Hands-free recording controls: delete, pause/resume, send.
struct LockedRecordingControls: View {
    @ObservedObject var recorder: VoiceRecorder
    let onSend: (RecordedVoiceMessage) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                recorder.cancel()
            } label: {
                Image(systemName: "trash")
                    .font(.title3)
            }
            .accessibilityLabel("Delete recording")

            VoiceRecordingBar(recorder: recorder)
                .frame(maxWidth: .infinity)

            Button {
                recorder.isPaused ? recorder.resume() : recorder.pause()
            } label: {
                Image(systemName: recorder.isPaused ? "mic.circle" : "pause.circle")
                    .font(.title2)
            }
            .accessibilityLabel(recorder.isPaused ? "Resume recording" : "Pause recording")

            Button {
                if let recorded = recorder.stop() {
                    onSend(recorded)
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .accessibilityLabel("Send voice message")
        }
    }
}

/// Playback bubble for a received or sent voice message.
struct VoiceMessageBubble: View {
    let duration: TimeInterval
    let waveform: [Float]
    let audioData: () async -> Data?
    /// The bubble's text colour (white on your own messages).
    var tint: Color

    @StateObject private var player = VoiceMessagePlayer()

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task { await togglePlayback() }
            } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView().tint(tint)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play voice message")

            VStack(alignment: .leading, spacing: 4) {
                StaticWaveform(samples: waveform, progress: player.progress, tint: tint)
                    .frame(height: 24)
                Text(timeString(player.isPlaying ? player.currentTime : duration))
                    .font(.caption2)
                    .foregroundStyle(tint)
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
            return
        }
        player.isLoading = true
        guard let data = await audioData() else {
            player.isLoading = false
            return
        }
        await player.play(data: data)
    }

    private func timeString(_ interval: TimeInterval) -> String {
        String(format: "%d:%02d", Int(interval) / 60, Int(interval) % 60)
    }
}

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
                        .fill(played ? tint : tint.opacity(0.35))
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
    @Published var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentTime: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// FIX: the audio session switch and the decoder setup run off the main
    /// thread (see `AudioSessionQueue`); only `play()` happens here.
    func play(data: Data) async {
        defer { isLoading = false }
        do {
            let player = try await AudioSessionQueue.run { () -> AVAudioPlayer in
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                let player = try AVAudioPlayer(data: data)
                player.prepareToPlay()
                return player
            }
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
        timer?.invalidate()
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
            AudioSessionQueue.deactivate()
        }
    }
}
