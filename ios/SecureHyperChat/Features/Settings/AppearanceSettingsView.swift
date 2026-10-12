import SwiftUI
import PhotosUI

/// Picks a background for all chats, one chat, or the rest of the app.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let scope: AppearanceScope

    @State private var draft: ChatAppearance = .default
    @State private var red: Double = 0.2
    @State private var green: Double = 0.4
    @State private var blue: Double = 0.8
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var errorMessage: String?

    init(scope: AppearanceScope) {
        self.scope = scope
    }

    init(conversationId: String?) {
        self.scope = conversationId.map { .conversation($0) } ?? .allChats
    }

    private var store: AppearanceStore { container.appearanceStore }

    /// The theme the draft would produce — the same one a real chat uses, so the
    /// preview and the result can't disagree.
    private var previewTheme: AppTheme { store.theme(for: draft) }

    var body: some View {
        NavigationStack {
            Form {
                ThemedSection("Preview") {
                    preview
                        .listRowInsets(EdgeInsets())
                }

                ThemedSection("Background") {
                    modeRow("System default", systemImage: "circle.lefthalf.filled", isSelected: isSystemDefault) {
                        draft.background = .systemDefault
                    }
                    modeRow("Solid colour", systemImage: "paintpalette", isSelected: isSolid) {
                        draft.background = .solid(red: red, green: green, blue: blue)
                    }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        HStack {
                            Label("Photo", systemImage: "photo")
                            Spacer()
                            if isImage { Image(systemName: "checkmark") }
                        }
                    }
                }

                if case .solid = draft.background {
                    ThemedSection("Colour") {
                        colorSlider("Red", value: $red, tint: .red)
                        colorSlider("Green", value: $green, tint: .green)
                        colorSlider("Blue", value: $blue, tint: .blue)
                        contrastReadout
                    }
                }

                if case .image = draft.background {
                    ThemedSection {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Dimming \(Int(draft.effectiveScrimOpacity * 100))%")
                                .font(.subheadline)
                            Slider(value: dimmingBinding, in: ContrastPolicy.minimumDarkScrimOpacity...0.9)
                        }
                    } footer: {
                        Text("Photos are dimmed so text stays readable. The minimum dimming can't be removed.")
                    }
                }

                ThemedSection {
                    Text("Bars, rows and incoming bubbles share one colour close to the background, and every piece of text on them is picked to stay readable.")
                        .font(.footnote)
                        .themedSecondary()
                }

                if store.hasOverride(scope: scope) {
                    ThemedSection {
                        ThemedRowButton(title: LocalizedStringKey(resetTitle), isDestructive: true) {
                            store.clear(scope: scope)
                            dismiss()
                        }
                    }
                }

                if let errorMessage {
                    ThemedSection { StatusText(errorMessage, .error) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            // FIX: was applied twice.
            .appScreenStyle()
            .onAppear(perform: loadDraft)
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
            .onChange(of: red) { _, _ in syncSolid() }
            .onChange(of: green) { _, _ in syncSolid() }
            .onChange(of: blue) { _, _ in syncSolid() }
        }
    }

    private var title: String {
        switch scope {
        case .allChats: return "Chat Background"
        case .chatList: return "App Background"
        case .conversation: return "This Chat"
        }
    }

    private var resetTitle: String {
        switch scope {
        case .allChats, .chatList: return "Use the default"
        case .conversation: return "Use the global chat background"
        }
    }

    private var isSystemDefault: Bool {
        if case .systemDefault = draft.background { return true }
        return false
    }

    private var isSolid: Bool {
        if case .solid = draft.background { return true }
        return false
    }

    private var isImage: Bool {
        if case .image = draft.background { return true }
        return false
    }

    private func modeRow(_ title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if isSelected { Image(systemName: "checkmark") }
            }
        }
    }

    private var dimmingBinding: Binding<Double> {
        Binding(
            get: { draft.effectiveScrimOpacity },
            set: { draft.bubbleOpacity = 1 - $0 }
        )
    }

    // MARK: Preview

    private var preview: some View {
        let theme = previewTheme
        return ZStack {
            ChatBackgroundView(appearance: draft) { store.imageURL(fileName: $0) }
                .frame(height: 240)
                .clipped()

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                    Circle().fill(.gray).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Maria").font(.subheadline.bold())
                        Text("online").font(.caption2.weight(.medium))
                    }
                    Spacer()
                    Image(systemName: "phone")
                    Image(systemName: "ellipsis.circle")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .notchStyle(theme.chrome, cornerRadius: 18)

                if scope == .chatList {
                    listRow("Maria", "See you at eight", theme: theme)
                    listRow("Alex", "📷 Photo", theme: theme)
                } else {
                    bubble("Are we still on for tonight?", isMine: false, theme: theme)
                    bubble("Yes — see you at eight.", isMine: true, theme: theme)
                }

                Spacer(minLength: 0)

                if scope != .chatList {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Capsule().fill(theme.fieldFill).frame(height: 28)
                        Image(systemName: "mic")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .notchStyle(theme.chrome, cornerRadius: 18)
                }
            }
            .padding(12)
        }
        .frame(height: 240)
    }

    private func bubble(_ text: String, isMine: Bool, theme: AppTheme) -> some View {
        HStack {
            if isMine { Spacer() }
            Text(text)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isMine ? theme.accentFill : theme.incomingBubbleFill)
                .foregroundStyle(isMine ? theme.accentText : theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !isMine { Spacer() }
        }
    }

    private func listRow(_ name: String, _ preview: String, theme: AppTheme) -> some View {
        HStack(spacing: 8) {
            Circle().fill(.gray).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.subheadline.bold())
                Text(preview).font(.caption)
            }
            Spacer()
        }
        .padding(8)
        .notchStyle(theme.chrome, cornerRadius: 14)
    }

    // MARK: Contrast readout

    private var contrastReadout: some View {
        let theme = previewTheme
        let luminance = ContrastPolicy.relativeLuminance(red: red, green: green, blue: blue)
        let textLuminance: Double = theme.textIsLight ? 1.0 : 0.0
        let ratio = ContrastPolicy.contrastRatio(luminanceA: luminance, luminanceB: textLuminance)
        return HStack {
            Image(systemName: ratio >= 4.5 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .themedStatus(ratio >= 4.5 ? .success : .warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Text contrast \(String(format: "%.1f", ratio)):1")
                    .font(.footnote)
                Text(theme.textIsLight ? "Light text chosen automatically." : "Dark text chosen automatically.")
                    .font(.caption2)
                    .themedSecondary()
            }
        }
    }

    private func colorSlider(_ label: String, value: Binding<Double>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label) \(Int(value.wrappedValue * 255))")
                .font(.caption)
                .themedSecondary()
            Slider(value: value, in: 0...1).tint(tint)
        }
    }

    // MARK: Actions

    private func loadDraft() {
        draft = store.appearance(scope: scope)
        if case .solid(let r, let g, let b) = draft.background {
            red = r; green = g; blue = b
        }
    }

    private func syncSolid() {
        guard case .solid = draft.background else { return }
        draft.background = .solid(red: red, green: green, blue: blue)
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            let fileName: String
            if let prepared = try? await PhotoAttachmentLoader.loadAndPrepare(item) {
                fileName = try store.saveBackgroundImage(prepared.imageData)
            } else if let data = try await item.loadTransferable(type: Data.self) {
                fileName = try store.saveBackgroundImage(data)
            } else {
                return
            }
            draft.background = .image(fileName: fileName)
        } catch {
            errorMessage = "Couldn't use that photo: \(error.localizedDescription)"
        }
    }

    private func save() {
        store.set(draft, scope: scope)
        dismiss()
    }
}
