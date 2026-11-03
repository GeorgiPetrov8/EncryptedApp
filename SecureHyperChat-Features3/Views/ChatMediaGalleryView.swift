import SwiftUI
import AVFoundation

/// #1: every photo, video, file and voice message in one chat.
///
/// Tapping an item closes the gallery and jumps to that message in the chat,
/// so the chat's own viewer, player and share options are reused.
///
/// Thumbnails are decoded at a small size (`ImageSafety`) and kept only in
/// memory. Opening the gallery loads previews as you scroll, which downloads
/// attachments that were never opened (the server deletes them after the first
/// download — that's the normal "open" path).
struct ChatMediaGalleryView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation
    let onOpen: (String) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case media = "Photos & Videos"
        case files = "Files & Voice"
        case starred = "Starred"
        var id: String { rawValue }
    }

    struct Item: Identifiable {
        let id: String
        let message: Message
        let kind: MediaType
        let isStarred: Bool
    }

    @State private var tab: Tab = .media
    @State private var items: [Item] = []
    @State private var starred: [Message] = []

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .media: mediaGrid
                case .files: filesList
                case .starred: starredList
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .navigationTitle("Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .appScreenStyle()
            .task { load() }
        }
    }

    // MARK: Tabs

    private var photosAndVideos: [Item] { items.filter { $0.kind == .image || $0.kind == .video } }
    private var filesAndVoice: [Item] { items.filter { $0.kind == .document || $0.kind == .audio } }

    @ViewBuilder
    private var mediaGrid: some View {
        if photosAndVideos.isEmpty {
            ThemedEmptyState(title: "No photos or videos", systemImage: "photo.on.rectangle", placement: .background)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photosAndVideos) { item in
                        GalleryThumb(item: item) { await container.messagingService.mediaDataOrNil(for: $0) }
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { open(item.id) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var filesList: some View {
        if filesAndVoice.isEmpty {
            ThemedEmptyState(title: "No files or voice messages", systemImage: "doc", placement: .background)
        } else {
            List {
                ThemedSection {
                    ForEach(filesAndVoice) { item in
                        Button { open(item.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.kind == .audio ? "waveform" : "doc.fill")
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(container.messagingService.previewText(for: item.message))
                                    Text(item.message.createdAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                                        .font(.caption)
                                        .themedSecondary()
                                }
                                Spacer()
                                if item.isStarred { Image(systemName: "star.fill").font(.caption) }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var starredList: some View {
        if starred.isEmpty {
            ThemedEmptyState(
                title: "No starred messages",
                systemImage: "star",
                description: "Long-press a message and choose Star to keep it here.",
                placement: .background
            )
        } else {
            List {
                ThemedSection {
                    ForEach(starred, id: \.id) { message in
                        Button { open(message.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(container.messagingService.previewText(for: message)).lineLimit(3)
                                Text(message.createdAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                                    .font(.caption)
                                    .themedSecondary()
                            }
                        }
                        .swipeActions {
                            Button("Unstar") { unstar(message) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Data

    private func load() {
        guard let me = container.authService.currentUserId else { return }
        let messages = (try? container.messageRepository.fetchMediaMessages(
            conversationId: conversation.id, ownerUserId: me
        )) ?? []
        items = messages.compactMap { message in
            guard !message.isUndecryptable,
                  let meta = container.messagingService.mediaDisplayMetadata(for: message),
                  !meta.isSticker else { return nil }
            return Item(id: message.id, message: message, kind: meta.mediaType, isStarred: message.isStarred)
        }
        starred = (try? container.messageRepository.fetchStarred(
            conversationId: conversation.id, ownerUserId: me
        )) ?? []
    }

    private func unstar(_ message: Message) {
        guard let me = container.authService.currentUserId else { return }
        try? container.messageRepository.setStarred(messageId: message.id, ownerUserId: me, isStarred: false)
        container.messagingService.conversationChanged.send(conversation.id)
        load()
    }

    private func open(_ messageId: String) {
        dismiss()
        // After the sheet is gone, so the scroll lands in the chat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpen(messageId) }
    }
}

private struct GalleryThumb: View {
    let item: ChatMediaGalleryView.Item
    let loader: (Message) async -> Data?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.gray.opacity(0.15)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: item.kind == .video ? "video.slash" : "photo").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, .black.opacity(0.4))
            }
            if item.isStarred {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .task(id: item.id) {
            guard let data = await loader(item.message) else { failed = true; return }
            if item.kind == .image {
                image = ImageSafety.downsampledImage(data, maxPixelSize: 300)
            } else {
                image = await Self.videoFrame(data)
            }
            failed = image == nil
        }
    }

    /// First frame of a video. The decrypted file exists only for the moment
    /// it takes, in the protected temp folder.
    private static func videoFrame(_ data: Data) async -> UIImage? {
        let url = ProtectedTemp.url(extension: "mp4", prefix: "thumb")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 300, height: 300)
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }
}
