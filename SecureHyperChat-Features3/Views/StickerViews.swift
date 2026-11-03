import SwiftUI
import PhotosUI

/// #7: your stickers — tap to send, "+" to make one from a photo.
struct StickerPickerSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let onSend: (Data) -> Void

    @State private var photo: PhotosPickerItem?
    @State private var creatorSource: Data?
    @State private var errorMessage: String?

    private var service: StickerService { container.stickerService }
    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        VStack(spacing: 4) {
                            Image(systemName: "plus").font(.title2)
                            Text("New").font(.caption)
                        }
                        .frame(width: 84, height: 84)
                        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])))
                    }

                    ForEach(service.stickers) { sticker in
                        StickerThumb(url: sticker.url)
                            .frame(width: 84, height: 84)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard let data = service.data(for: sticker) else { return }
                                service.touch(sticker)
                                onSend(data)
                                dismiss()
                            }
                            .contextMenu {
                                Button(role: .destructive) { service.delete(sticker) } label: {
                                    Label("Delete sticker", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding()

                if service.stickers.isEmpty {
                    Text("Make stickers from your own photos. They're kept only on this phone.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .themedSecondary()
                        .padding()
                }
                if let errorMessage {
                    StatusText(errorMessage, .error).padding()
                }
            }
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .appScreenStyle()
            .onAppear { service.reload() }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    defer { photo = nil }
                    creatorSource = try? await item.loadTransferable(type: Data.self)
                    if creatorSource == nil { errorMessage = "That photo couldn't be loaded." }
                }
            }
            .sheet(isPresented: Binding(get: { creatorSource != nil }, set: { if !$0 { creatorSource = nil } })) {
                if let creatorSource {
                    StickerCreatorSheet(source: creatorSource).environmentObject(container)
                }
            }
        }
    }
}

/// Preview the sticker (cut-out or square) and add it to the collection.
struct StickerCreatorSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let source: Data

    @State private var cutout = true
    @State private var result: Data?
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Picker("Style", selection: $cutout) {
                    Text("Cut out").tag(true)
                    Text("Square").tag(false)
                }
                .pickerStyle(.segmented)

                ZStack {
                    CheckerboardBackground().clipShape(RoundedRectangle(cornerRadius: 16))
                    if let result, let image = UIImage(data: result) {
                        Image(uiImage: image).resizable().scaledToFit().padding(12)
                    } else if working {
                        ProgressView()
                    }
                }
                .frame(width: 240, height: 240)

                if let errorMessage { StatusText(errorMessage, .error) }

                Text("Made on this phone. Cut-out needs a clear subject (a person, pet or object).")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .themedSecondary()
                Spacer()
            }
            .padding()
            .navigationTitle("New Sticker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let result else { return }
                        do { try container.stickerService.add(png: result); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }
                    .bold()
                    .disabled(result == nil)
                }
            }
            .appScreenStyle()
            .task(id: cutout) { await build() }
        }
    }

    private func build() async {
        working = true
        result = nil
        errorMessage = nil
        defer { working = false }
        do {
            result = try await StickerService.makeSticker(from: source, cutout: cutout)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A sticker in the chat: no bubble, transparent background.
struct StickerBubble: View {
    let messageId: String
    let loader: (String) async -> Data?
    var onSave: ((Data) -> Void)?

    @State private var image: UIImage?
    @State private var data: Data?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "face.dashed").font(.largeTitle).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(width: 150, height: 150)
        .contextMenu {
            if let data, let onSave {
                Button { onSave(data) } label: { Label("Save to my stickers", systemImage: "square.and.arrow.down") }
            }
        }
        .task(id: messageId) {
            guard let loaded = await loader(messageId),
                  let decoded = ImageSafety.downsampledImage(loaded, maxPixelSize: 400) else {
                failed = true
                return
            }
            data = loaded
            image = decoded
        }
        .accessibilityLabel("Sticker")
    }
}

private struct StickerThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() } else { Color.clear }
        }
        .task(id: url) {
            if let data = try? Data(contentsOf: url) {
                image = ImageSafety.downsampledImage(data, maxPixelSize: 200)
            }
        }
    }
}

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 12
            for row in 0..<Int(size.height / cell) + 1 {
                for col in 0..<Int(size.width / cell) + 1 where (row + col) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}
