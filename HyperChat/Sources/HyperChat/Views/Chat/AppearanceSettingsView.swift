import SwiftUI
import PhotosUI

/// Picks a background, either globally or for one conversation.
///
/// Shows a live preview with real bubbles rather than a colour swatch, because
/// the thing the user actually needs to judge is "can I read my messages on
/// this", which a swatch doesn't answer.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    /// `nil` edits the global default; non-nil edits one conversation.
    let conversationId: String?

    @State private var draft: ChatAppearance = .default
    @State private var red: Double = 0.2
    @State private var green: Double = 0.4
    @State private var blue: Double = 0.8
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var errorMessage: String?

    private var store: AppearanceStore { container.appearanceStore }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") {
                    preview
                        .listRowInsets(EdgeInsets())
                }

                Section("Background") {
                    Button {
                        draft.background = .systemDefault
                    } label: {
                        Label("System default", systemImage: "circle.lefthalf.filled")
                    }

                    Button {
                        draft.background = .solid(red: red, green: green, blue: blue)
                    } label: {
                        Label("Solid colour", systemImage: "paintpalette")
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Photo", systemImage: "photo")
                    }
                }

                if case .solid = draft.background {
                    Section("Colour") {
                        colorSlider("Red", value: $red, tint: .red)
                        colorSlider("Green", value: $green, tint: .green)
                        colorSlider("Blue", value: $blue, tint: .blue)
                        contrastReadout
                    }
                }

                if case .image = draft.background {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Dimming")
                                .font(.subheadline)
                            Slider(value: $draft.bubbleOpacity, in: 0...0.5)
                        }
                    } footer: {
                        // Explains why the slider refuses to go to zero, which
                        // otherwise reads as a bug rather than a guardrail.
                        Text("Photos are dimmed so message text stays readable. The minimum dimming can't be removed — over a bright photo, undimmed text becomes unreadable.")
                    }
                }

                if let conversationId, store.hasOverride(for: conversationId) {
                    Section {
                        Button("Use the global background", role: .destructive) {
                            store.clearOverride(for: conversationId)
                            dismiss()
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(conversationId == nil ? "Chat Background" : "This Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
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

    // MARK: Preview

    private var preview: some View {
        ZStack {
            ChatBackgroundView(appearance: draft) { store.imageURL(fileName: $0) }
                .frame(height: 180)
                .clipped()

            VStack(alignment: .leading, spacing: 8) {
                bubble("Are we still on for tonight?", isMine: false)
                bubble("Yes — see you at eight.", isMine: true)
            }
            .padding()
        }
        .frame(height: 180)
    }

    private func bubble(_ text: String, isMine: Bool) -> some View {
        HStack {
            if isMine { Spacer() }
            Text(text)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isMine ? Color.accentColor : draft.incomingBubbleColor)
                .foregroundStyle(isMine ? Color.white : draft.foregroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !isMine { Spacer() }
        }
    }

    // MARK: Contrast readout

    /// Shown because the auto-contrast rule is invisible otherwise — a user who
    /// drags the sliders sees the text colour flip from black to white at the
    /// midpoint and deserves to know that was deliberate, not a glitch.
    private var contrastReadout: some View {
        let luminance = ContrastPolicy.relativeLuminance(red: red, green: green, blue: blue)
        let textLuminance: Double = draft.prefersLightForeground ? 1.0 : 0.0
        let ratio = ContrastPolicy.contrastRatio(luminanceA: luminance, luminanceB: textLuminance)

        return HStack {
            Image(systemName: ratio >= 4.5 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ratio >= 4.5 ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Text contrast \(String(format: "%.1f", ratio)):1")
                    .font(.footnote)
                Text(draft.prefersLightForeground
                     ? "Light text chosen automatically."
                     : "Dark text chosen automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func colorSlider(_ label: String, value: Binding<Double>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label) \(Int(value.wrappedValue * 255))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: 0...1).tint(tint)
        }
    }

    // MARK: Actions

    private func loadDraft() {
        draft = store.appearance(for: conversationId)
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
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            // Reuses the message-attachment downsampler: a full-resolution
            // photo as a wallpaper is a waste of disk and of decode time on
            // every chat open.
            guard let prepared = try? await PhotoAttachmentLoader.loadAndPrepare(item) else {
                let fileName = try store.saveBackgroundImage(data)
                draft.background = .image(fileName: fileName)
                return
            }
            let fileName = try store.saveBackgroundImage(prepared.imageData)
            draft.background = .image(fileName: fileName)
        } catch {
            errorMessage = "Couldn't use that photo: \(error.localizedDescription)"
        }
    }

    private func save() {
        if let conversationId {
            store.setAppearance(draft, for: conversationId)
        } else {
            store.setGlobal(draft)
        }
        dismiss()
    }
}
