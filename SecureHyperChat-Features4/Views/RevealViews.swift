import SwiftUI

/// #19: the gates in front of a message. Each calls `onOpened` once; the chat
/// then remembers it (`revealedAt`) and shows the real bubble from then on.

// MARK: Gift

struct GiftWrapView: View {
    let textColor: Color
    let bubbleColor: Color
    let onOpened: () -> Void

    @State private var shaking = false
    @State private var opening = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.45)) { opening = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onOpened() }
        } label: {
            VStack(spacing: 6) {
                Text("🎁")
                    .font(.system(size: 52))
                    .rotationEffect(.degrees(shaking ? 6 : -6))
                    .scaleEffect(opening ? 1.6 : 1)
                    .opacity(opening ? 0 : 1)
                Text("You received a gift").font(.subheadline.weight(.semibold))
                Text("Tap to unwrap").font(.caption)
            }
            .padding(16)
            .frame(width: 200)
            .background(bubbleColor)
            .foregroundStyle(textColor)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { shaking = true }
        }
        .accessibilityLabel("Gift. Double tap to unwrap.")
    }
}

// MARK: Secret — hold

struct HoldToRevealView: View {
    let textColor: Color
    let bubbleColor: Color
    let onOpened: () -> Void

    @State private var progress: CGFloat = 0
    @State private var holding = false
    private let duration = 1.5

    var body: some View {
        VStack(spacing: 8) {
            Text("🧩 Secret message").font(.subheadline.weight(.semibold))
            ZStack(alignment: .leading) {
                Capsule().fill(textColor.opacity(0.2))
                Capsule().fill(textColor).frame(width: 180 * progress)
            }
            .frame(width: 180, height: 8)
            Text(holding ? "Keep holding…" : "Press and hold to reveal").font(.caption)
        }
        .padding(14)
        .background(bubbleColor)
        .foregroundStyle(textColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 30) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onOpened()
        } onPressingChanged: { pressing in
            holding = pressing
            withAnimation(pressing ? .linear(duration: duration) : .easeOut(duration: 0.2)) {
                progress = pressing ? 1 : 0
            }
        }
        .accessibilityLabel("Secret message")
        .accessibilityAction(named: "Reveal") { onOpened() }
    }
}

// MARK: Secret — slide puzzle

/// 3×3 sliding puzzle. Shuffled by random legal moves from the solved position,
/// so it's always solvable (checked on 5000 shuffles).
struct SlidePuzzleView: View {
    let textColor: Color
    let bubbleColor: Color
    let onOpened: () -> Void

    @State private var board: [Int] = SlidePuzzle.shuffled()
    @State private var solved = false
    private let tile: CGFloat = 54

    var body: some View {
        VStack(spacing: 8) {
            Text("🧩 Solve to reveal").font(.subheadline.weight(.semibold))
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { col in
                            let index = row * 3 + col
                            let value = board[index]
                            Button {
                                guard !solved else { return }
                                withAnimation(.easeOut(duration: 0.12)) { board = SlidePuzzle.tap(board, index) }
                                if board == SlidePuzzle.solved {
                                    solved = true
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onOpened() }
                                }
                            } label: {
                                Text(value == 0 ? "" : "\(value)")
                                    .font(.headline.monospacedDigit())
                                    .frame(width: tile, height: tile)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(value == 0 ? Color.clear : textColor.opacity(0.18))
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(value == 0 ? "Empty" : "Tile \(value)")
                        }
                    }
                }
            }
            Text("Tap a tile next to the gap. Order 1–8.").font(.caption2)
        }
        .padding(12)
        .background(bubbleColor)
        .foregroundStyle(textColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityAction(named: "Skip puzzle and reveal") { onOpened() }
    }
}

enum SlidePuzzle {
    static let solved = Array(1...8) + [0]

    static func neighbours(_ index: Int) -> [Int] {
        let row = index / 3, col = index % 3
        var out: [Int] = []
        if row > 0 { out.append(index - 3) }
        if row < 2 { out.append(index + 3) }
        if col > 0 { out.append(index - 1) }
        if col < 2 { out.append(index + 1) }
        return out
    }

    static func shuffled(moves: Int = 60) -> [Int] {
        var board = solved
        var previous = -1
        for _ in 0..<moves {
            guard let gap = board.firstIndex(of: 0) else { break }
            let options = neighbours(gap).filter { $0 != previous }
            guard let pick = options.randomElement() else { continue }
            board.swapAt(gap, pick)
            previous = gap
        }
        return board == solved ? shuffled(moves: moves) : board
    }

    static func tap(_ board: [Int], _ index: Int) -> [Int] {
        guard let gap = board.firstIndex(of: 0), neighbours(gap).contains(index) else { return board }
        var copy = board
        copy.swapAt(gap, index)
        return copy
    }
}

// MARK: Locked until

struct LockedUntilView: View {
    let unlocksAt: Date
    let textColor: Color
    let bubbleColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Locked message", systemImage: "lock.fill").font(.subheadline.weight(.semibold))
            Text("Opens \(unlocksAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            Text(unlocksAt, style: .relative).font(.caption2.monospacedDigit())
        }
        .padding(12)
        .background(bubbleColor)
        .foregroundStyle(textColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Pinned at the top of the chat while a message from them is still locked.
struct PinnedLockedStrip: View {
    let unlocksAt: Date
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                Text(count == 1 ? "A locked message opens" : "\(count) locked messages · next opens")
                Text(unlocksAt, style: .relative).monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption)
            }
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Disappearing / view-once placeholders

struct ConsumeOnViewBubble: View {
    let contentType: MessageContentType
    let isMine: Bool
    let consumed: Bool
    let screenshotTaken: Bool
    let textColor: Color
    let bubbleColor: Color
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let subtitle { Text(subtitle).font(.caption) }
                    if screenshotTaken { Text("📸 Screenshot taken").font(.caption2) }
                }
            }
            .padding(12)
            .background(bubbleColor)
            .foregroundStyle(textColor)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(consumed ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isMine || consumed)
    }

    private var isText: Bool { contentType == .text }
    private var icon: String { consumed ? "checkmark.circle" : (isText ? "wind" : "eye") }

    private var title: String {
        if consumed { return isText ? "Message disappeared" : "Opened" }
        if isText { return isMine ? "Disappearing message" : "Tap to read once" }
        let kind = contentType == .video ? "video" : "photo"
        return isMine ? "View-once \(kind)" : "Tap to view \(kind) once"
    }

    private var subtitle: String? {
        guard !consumed else { return nil }
        if isMine { return "Not opened yet" }
        return isText ? nil : "Only while you're online"
    }
}

/// Own scheduled message: time + cancel.
struct ScheduledBadge: View {
    let scheduledFor: Date
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge")
            Text("Scheduled · \(scheduledFor.formatted(date: .abbreviated, time: .shortened))")
            Button("Cancel", role: .destructive, action: onCancel)
                .font(.caption2.weight(.semibold))
        }
        .font(.caption2)
    }
}
