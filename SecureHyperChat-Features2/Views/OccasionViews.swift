import SwiftUI

/// #15: confetti that falls for a few seconds and goes away by itself.
/// With "Reduce Motion" on, nothing moves — only the banner is shown.
struct ConfettiView: View {
    var duration: TimeInterval = 3.5
    var onFinished: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var particles: [Particle] = []

    private struct Particle {
        let x: Double, delay: Double, speed: Double, drift: Double, spin: Double, size: Double
        let color: Color
    }

    var body: some View {
        Group {
            if reduceMotion {
                Color.clear
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        let t = timeline.date.timeIntervalSince(start)
                        for p in particles {
                            let local = t - p.delay
                            guard local > 0 else { continue }
                            let y = local * p.speed * size.height - 20
                            guard y < size.height + 20 else { continue }
                            let x = p.x * size.width + sin(local * 3 + p.drift) * 25
                            var piece = context
                            piece.translateBy(x: x, y: y)
                            piece.rotate(by: .radians(local * p.spin))
                            piece.opacity = max(0, 1 - local / duration)
                            piece.fill(Path(CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)),
                                       with: .color(p.color))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            start = Date()
            let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]
            particles = (0..<90).map { _ in
                Particle(
                    x: .random(in: 0...1), delay: .random(in: 0...0.8), speed: .random(in: 0.25...0.45),
                    drift: .random(in: 0...6), spin: .random(in: -6...6), size: .random(in: 6...11),
                    color: colors.randomElement() ?? .pink
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : duration + 0.9)) { onFinished() }
        }
    }
}

/// #15: set or remove the shared date (Chat menu → "Shared date").
struct OccasionSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation
    let peerName: String

    @State private var kind: Occasion.Kind = .anniversary
    @State private var label = ""
    @State private var date = Date()
    @State private var includeYear = true
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var existing: Occasion? { container.occasionService.occasion(for: conversation.id) }

    var body: some View {
        NavigationStack {
            Form {
                ThemedSection {
                    Picker("Type", selection: $kind) {
                        ForEach(Occasion.Kind.allCases) { Text("\($0.emoji) \($0.title)").tag($0) }
                    }
                    TextField("Label (optional)", text: $label)
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                    Toggle("Count the years", isOn: $includeYear)
                } footer: {
                    Text("Shared with \(peerName). On that day, every year, the chat shows confetti on both phones.")
                }

                if existing != nil {
                    ThemedSection {
                        ThemedRowButton(title: "Remove shared date", isDestructive: true) {
                            run { try await container.occasionService.remove(in: conversation) }
                        }
                    }
                }

                if let errorMessage {
                    ThemedSection { StatusText(errorMessage, .error) }
                }
            }
            .navigationTitle("Shared Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.bold().disabled(isSaving)
                }
            }
            .appScreenStyle()
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let existing else { return }
        kind = existing.kind
        label = existing.label ?? ""
        includeYear = existing.year != nil
        var components = DateComponents()
        components.year = existing.year ?? Calendar.current.component(.year, from: Date())
        components.month = existing.month
        components.day = existing.day
        date = Calendar.current.date(from: components) ?? Date()
    }

    private func save() {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let month = c.month, let day = c.day else { return }
        run {
            try await container.occasionService.set(
                kind: kind, label: label, month: month, day: day,
                year: includeYear ? c.year : nil, in: conversation
            )
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await action()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
