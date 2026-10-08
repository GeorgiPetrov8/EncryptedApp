import SwiftUI

/// Live waveform shown while recording a voice message.
///
/// FIX (no movement during the first second): the microphone hardware needs
/// roughly half a second to a second to start delivering audio after the
/// session switches to recording. During that time the meter reads silence,
/// so a waveform driven only by the level stood still and looked frozen.
///
/// This view always moves:
///   - it advances on its own 20 Hz ticker, registered in `.common` run-loop
///     mode so it keeps firing while a finger is held on the mic button;
///   - each bar is `max(level, idle)`, where `idle` is a gentle "breathing"
///     wave — real sound takes over as soon as it is louder than that.
struct RecordingWaveform: View {
    let level: Float
    var isPaused = false
    var barCount = 20
    var color: Color = .red

    @State private var history: [CGFloat]
    @State private var phase: Double = 0

    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    init(level: Float, isPaused: Bool = false, barCount: Int = 20, color: Color = .red) {
        self.level = level
        self.isPaused = isPaused
        self.barCount = barCount
        self.color = color
        _history = State(initialValue: Array(repeating: 0.1, count: barCount))
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.85))
                    .frame(width: 2, height: max(3, history[index] * 20))
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.05), value: history)
        .onReceive(ticker) { _ in
            guard !isPaused else { return }
            phase += 0.35
            let idle = 0.10 + 0.06 * sin(phase)
            let sample = max(CGFloat(level), idle)
            history.removeFirst()
            history.append(min(sample, 1))
        }
        .accessibilityHidden(true)
    }
}
