import SwiftUI

/// #12 / #19: options for the **next** message (text, photo or video), opened
/// from the ✨ button in the composer. Reset after that message is sent.
struct SendOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var options: SendOptions
    @Binding var scheduledFor: Date?

    @State private var secret = false
    @State private var reveal: SendOptions.Reveal = .hold
    @State private var gift = false
    @State private var disappear = false
    @State private var lock = false
    @State private var lockDate = Date().addingTimeInterval(24 * 3600)
    @State private var later = false
    @State private var laterDate = Date().addingTimeInterval(3600)

    var body: some View {
        NavigationStack {
            Form {
                ThemedSection {
                    Toggle("🎁 Gift wrap", isOn: $gift)
                } footer: {
                    Text("They see a gift and unwrap it to find the message, photo, video or GIF.")
                }

                ThemedSection {
                    Toggle("🧩 Secret message", isOn: $secret)
                    if secret {
                        Picker("To open", selection: $reveal) {
                            ForEach(SendOptions.Reveal.allCases) { Text($0.title).tag($0) }
                        }
                    }
                } footer: {
                    Text("Hidden until they hold it or solve a small puzzle.")
                }

                ThemedSection {
                    Toggle("💨 Disappears after reading / view once", isOn: $disappear)
                } footer: {
                    Text("Text: gone from both phones once read. Photo/video: opens once, only online, and is deleted from their phone and the server. Their app enforces this — a screenshot or a second camera can't be stopped, though screenshots are reported.")
                }

                ThemedSection {
                    Toggle("🔒 Locked until", isOn: $lock)
                    if lock {
                        DatePicker("Opens", selection: $lockDate,
                                   in: Date().addingTimeInterval(60)...Date().addingTimeInterval(SendOptions.maxLockDuration))
                    }
                } footer: {
                    Text("Delivered now and pinned at the top of their chat, but readable only from that moment.")
                }

                ThemedSection {
                    Toggle("⏰ Send later", isOn: $later)
                    if later {
                        DatePicker("Send at", selection: $laterDate,
                                   in: Date().addingTimeInterval(60)...Date().addingTimeInterval(ScheduledSendService.maxAhead))
                    }
                } footer: {
                    Text("Stays on this phone until then. If SecureHyperChat is closed at that time, you'll get a notification and it's sent when you open the app.")
                }
            }
            .navigationTitle("Send Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        options = .none
                        scheduledFor = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply() }.bold()
                }
            }
            .appScreenStyle()
            .onAppear(perform: load)
        }
    }

    private func load() {
        secret = options.reveal != nil
        reveal = options.reveal ?? .hold
        gift = options.isGift
        disappear = options.consumes
        if let unlocksAt = options.unlocksAt { lock = true; lockDate = unlocksAt }
        if let scheduledFor { later = true; laterDate = scheduledFor }
    }

    private func apply() {
        options = SendOptions(
            reveal: secret ? reveal : nil,
            gift: gift ? true : nil,
            consumeOnView: disappear ? true : nil,
            unlocksAt: lock ? lockDate : nil
        )
        scheduledFor = later ? laterDate : nil
        dismiss()
    }
}

/// Little chips above the composer showing what the next message will be.
struct SendOptionsChips: View {
    let options: SendOptions
    let scheduledFor: Date?
    let onTap: () -> Void

    var body: some View {
        let chips = labels
        if !chips.isEmpty {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { Text($0).font(.caption2.weight(.semibold)) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().strokeBorder(lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send options: \(chips.joined(separator: ", "))")
        }
    }

    private var labels: [String] {
        var out: [String] = []
        if options.isGift { out.append("🎁 Gift") }
        if options.reveal != nil { out.append("🧩 Secret") }
        if options.consumes { out.append("💨 Once") }
        if let unlocksAt = options.unlocksAt { out.append("🔒 \(unlocksAt.formatted(date: .abbreviated, time: .shortened))") }
        if let scheduledFor { out.append("⏰ \(scheduledFor.formatted(date: .abbreviated, time: .shortened))") }
        return out
    }
}
