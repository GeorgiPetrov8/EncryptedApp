import SwiftUI

/// The small line under the name in the chat header: "typing…", "online",
/// and (if they share it) "🔋 64%". Shows nothing when there's nothing to say —
/// never "offline" or "last seen".
struct PeerStatusLine: View {
    let isOnline: Bool
    let isTyping: Bool
    let battery: BatteryShareService.Reading?

    var body: some View {
        let parts = items
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .accessibilityLabel(accessibility)
        }
    }

    private var items: [String] {
        var out: [String] = []
        if isTyping { out.append("typing…") } else if isOnline { out.append("online") }
        if let battery { out.append("\(battery.charging ? "⚡️" : "🔋") \(battery.level)%") }
        return out
    }

    private var accessibility: String {
        var out: [String] = []
        if isTyping { out.append("Typing") } else if isOnline { out.append("Online") }
        if let battery { out.append("Battery \(battery.level) percent\(battery.charging ? ", charging" : "")") }
        return out.joined(separator: ", ")
    }
}

/// "typing…" with three bouncing dots, shown above the composer.
struct TypingIndicator: View {
    let name: String
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3) { index in
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(phase == index ? 1 : 0.35)
                }
            }
            Text("\(name) is typing…")
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                phase = (phase + 1) % 3
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) is typing")
    }
}
