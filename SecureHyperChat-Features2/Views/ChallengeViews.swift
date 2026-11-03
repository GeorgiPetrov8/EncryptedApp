import SwiftUI

/// #20: the card in the chat.
struct ChallengeCardView: View {
    let card: ChallengeCard
    let status: ChallengeStatus
    let isMine: Bool
    let textColor: Color
    let bubbleColor: Color
    let onRespond: (ChallengeStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(card.category.emoji)
                Text("\(card.category.title) challenge")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                Spacer(minLength: 8)
                Text(status.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(textColor.opacity(0.6), lineWidth: 1))
            }

            Text(card.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = card.detail {
                Text(detail)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(bubbleColor)
        .foregroundStyle(textColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(textColor.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        if isMine {
            Text(status == .sent ? "Waiting for them to answer." : "You'll see when they finish.")
                .font(.caption)
        } else {
            switch status {
            case .sent:
                HStack(spacing: 8) {
                    pill("Accept") { onRespond(.accepted) }
                    pill("Not now") { onRespond(.declined) }
                }
            case .accepted:
                HStack(spacing: 8) {
                    pill("Mark done") { onRespond(.completed) }
                    pill("Give up") { onRespond(.declined) }
                }
            case .declined, .completed:
                EmptyView()
            }
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(textColor, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// #20: pick a challenge from the list (or write your own) and send it.
struct ChallengePickerSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let onSend: (ChallengeCard) -> Void

    @State private var category: ChallengeCategory = .fun
    @State private var customTitle = ""
    @State private var customDetail = ""

    private var catalog: ChallengeCatalog { .bundled }
    private var categories: [ChallengeCategory] { container.challengeService.availableCategories }

    var body: some View {
        NavigationStack {
            List {
                ThemedSection {
                    Picker("Category", selection: $category) {
                        ForEach(categories) { Text("\($0.emoji) \($0.title)").tag($0) }
                    }
                    .pickerStyle(.menu)

                    Button {
                        if let random = catalog.items(in: category).randomElement() { send(random.card) }
                    } label: {
                        Label("Surprise me", systemImage: "dice")
                    }
                    .disabled(catalog.items(in: category).isEmpty)
                }

                ThemedSection {
                    ForEach(catalog.items(in: category), id: \.id) { item in
                        Button { send(item.card) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline.weight(.semibold))
                                if let detail = item.detail {
                                    Text(detail).font(.caption).themedSecondary()
                                }
                            }
                        }
                    }
                } header: {
                    Text("\(category.emoji) \(category.title)")
                }

                ThemedSection {
                    TextField("Your challenge", text: $customTitle)
                    TextField("Details (optional)", text: $customDetail, axis: .vertical)
                        .lineLimit(1...4)
                    Button("Send my own") {
                        send(ChallengeCard(id: "custom", category: category, title: customTitle, detail: customDetail))
                    }
                    .disabled(customTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Write your own")
                }

                if !container.challengeService.spicyEnabled {
                    ThemedSection {
                        Text("Spicy challenges are hidden. Turn them on in Settings → Challenges (18+).")
                            .font(.footnote)
                            .themedSecondary()
                    }
                }
            }
            .navigationTitle("Send a Challenge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .appScreenStyle()
            .onAppear { if !categories.contains(category) { category = .fun } }
        }
    }

    private func send(_ card: ChallengeCard) {
        guard let valid = card.validated() else { return }
        onSend(valid)
        dismiss()
    }
}

/// #20: Settings → Challenges. Spicy needs an explicit 18+ confirmation.
struct ChallengeSettingsSection: View {
    @EnvironmentObject private var container: AppContainer
    @State private var confirmAge = false

    var body: some View {
        ThemedSection {
            Toggle("Show spicy challenges", isOn: Binding(
                get: { container.challengeService.spicyEnabled },
                set: { on in
                    if on { confirmAge = true } else { container.challengeService.spicyEnabled = false }
                }
            ))
        } header: {
            Text("Challenges")
        } footer: {
            Text("Spicy challenges are flirty and meant for couples. They're off by default; only you see this setting.")
        }
        .confirmationDialog("Are you 18 or older?", isPresented: $confirmAge, titleVisibility: .visible) {
            Button("Yes, I'm 18+") { container.challengeService.spicyEnabled = true }
            Button("Cancel", role: .cancel) {}
        }
    }
}
