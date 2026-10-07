import SwiftUI

struct MessageBubbleView: View {
    let message: DisplayMessage
    let peerIsVerified: Bool
    var allowGIFAutoload: Bool = false
    var canReact: Bool = true
    var mediaLoader: (String) async -> Data? = { _ in nil }
    var onReply: () -> Void = {}
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    var onQuoteTap: (String) -> Void = { _ in }
    var onReact: (String?) -> Void = { _ in }
    /// NEW: opens the full emoji picker.
    var onMoreReactions: () -> Void = {}
    var onShare: () async -> Void = {}
    var onPlayVideo: () async -> Void = {}

    @Environment(\.chatAppearance) private var appearance

    @State private var swipeOffset: CGFloat = 0
    @State private var swipeArmed = false

    private let replyThreshold: CGFloat = 60
    private var swipeSign: CGFloat { message.isMine ? -1 : 1 }

    /// The shape iOS uses for the long-press preview.
    ///
    /// FIX (square box behind the bubble): without it the preview is the
    /// view's rectangular frame drawn on the system background — visible as a
    /// square "shadow box" on the default background, and blending in on a
    /// custom one. With the bubble's own shape there's no box at all.
    private static let bubbleShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 40) }

            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
                bubble
                    .contentShape(.contextMenuPreview, Self.bubbleShape)
                    .contextMenu { contextMenu }
                if !message.reactions.isEmpty {
                    ReactionBar(reactions: message.reactions) { reaction in
                        onReact(reaction.includesMe ? nil : reaction.emoji)
                    }
                }
                footer
            }
            .offset(x: swipeOffset)

            if !message.isMine { Spacer(minLength: 40) }
        }
        .overlay(alignment: message.isMine ? .trailing : .leading) { replyHint }
        .simultaneousGesture(swipeToReply)
    }

    // MARK: Swipe to reply

    private var swipeToReply: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) * 1.5 else { return }
                let along = dx * swipeSign
                guard along > 0 else {
                    swipeOffset = 0
                    return
                }
                swipeOffset = min(along, replyThreshold + 20) * swipeSign
                if along >= replyThreshold, !swipeArmed {
                    swipeArmed = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .onEnded { _ in
                if swipeArmed { onReply() }
                swipeArmed = false
                withAnimation(.spring(duration: 0.25)) { swipeOffset = 0 }
            }
    }

    private var replyHint: some View {
        let progress = min(1, abs(swipeOffset) / replyThreshold)
        return Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(swipeArmed ? Color.brand : Color.primary)
            .frame(width: 34, height: 34)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            .scaleEffect(swipeArmed ? 1.1 : 0.6 + 0.4 * progress)
            .opacity(progress)
            .padding(.horizontal, 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Long-press menu

    @ViewBuilder
    private var contextMenu: some View {
        if canReact, message.status != .undecryptable {
            ControlGroup {
                ForEach(ReactionPayload.quickReactions, id: \.self) { emoji in
                    Button(emoji) {
                        onReact(message.myReaction == emoji ? nil : emoji)
                    }
                }
            }
            .controlGroupStyle(.palette)

            // NEW: any emoji, not only the quick ones (the palette shows as
            // many as fit, which can be just four on smaller phones).
            Button {
                onMoreReactions()
            } label: {
                Label("Add reaction…", systemImage: "face.smiling")
            }
        }

        Button {
            onReply()
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        if let copyText = message.copyText {
            Button {
                UIPasteboard.general.string = copyText
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        if message.isMediaAttachment {
            Button {
                Task { await onShare() }
            } label: {
                Label(saveLabel, systemImage: "square.and.arrow.down")
            }
        }
        if message.canEdit {
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
        if message.myReaction != nil {
            Button {
                onReact(nil)
            } label: {
                Label("Remove reaction", systemImage: "face.dashed")
            }
        }
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete for me", systemImage: "trash")
        }
    }

    private var saveLabel: String {
        switch message.contentType {
        case .image: return "Save / Share Photo"
        case .video: return "Save / Share Video"
        default: return "Save / Share File"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: lockIcon)
                .font(.caption2)
                .accessibilityLabel(lockAccessibilityLabel)
            if message.isEdited {
                Text("edited")
                    .font(.caption2.italic())
            }
            Text(message.createdAt, style: .time)
                .font(.caption2)
            if message.isMine {
                MessageStatusView(
                    status: message.status,
                    deliveredAt: message.deliveredAt,
                    readAt: message.readAt,
                    tint: appearance.secondaryForegroundColor
                )
            } else if message.status == .undecryptable {
                Image(systemName: "exclamationmark.octagon")
                    .font(.caption2)
            }
        }
        .foregroundStyle(message.status == .undecryptable ? Color.orange : appearance.secondaryForegroundColor)
    }

    // MARK: Bubble

    @ViewBuilder
    private var bubble: some View {
        if message.status == .undecryptable {
            Text(message.text)
                .font(.footnote)
                .italic()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(.orange)
                .overlay(
                    Self.bubbleShape
                        .strokeBorder(.orange, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        } else if let gif = message.gif {
            VStack(alignment: .leading, spacing: 6) {
                if let reply = message.replyTo {
                    ReplyQuoteView(reply: reply, authorName: message.replyAuthorName ?? "", textColor: textColor)
                        .onTapGesture { onQuoteTap(reply.messageId) }
                        .padding([.horizontal, .top], 6)
                }
                GIFMessageView(gif: gif, autoload: allowGIFAutoload)
            }
            .background(message.replyTo == nil ? Color.clear : bubbleColor)
            .clipShape(Self.bubbleShape)
        } else if message.contentType == .image {
            MediaMessageView(messageId: message.id, mediaLoader: mediaLoader)
                .clipShape(Self.bubbleShape)
        } else if message.contentType == .video {
            VideoMessageView(onPlay: onPlayVideo)
        } else if message.contentType == .file, message.mediaType == .audio {
            VoiceMessageBubble(
                duration: message.voiceDuration ?? 0,
                waveform: message.voiceWaveform ?? [],
                audioData: { await mediaLoader(message.id) },
                tint: textColor
            )
            .background(bubbleColor)
            .clipShape(Self.bubbleShape)
        } else if message.contentType == .file {
            FileMessageView(
                title: "Document",
                textColor: textColor,
                bubbleColor: bubbleColor,
                onOpen: onShare
            )
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let reply = message.replyTo {
                    ReplyQuoteView(
                        reply: reply,
                        authorName: message.replyAuthorName ?? "",
                        textColor: textColor
                    )
                    .onTapGesture { onQuoteTap(reply.messageId) }
                }
                Text(message.text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bubbleColor)
            .foregroundStyle(textColor)
            .clipShape(Self.bubbleShape)
        }
    }

    /// FIX: `.brand`, not `Color.brand` — see `Color.brand`.
    private var bubbleColor: Color {
        message.isMine ? Color.brand : appearance.incomingBubbleColor
    }

    private var textColor: Color {
        message.isMine ? Color.white : appearance.foregroundColor
    }

    private var lockIcon: String {
        if message.status == .undecryptable { return "lock.trianglebadge.exclamationmark" }
        return peerIsVerified ? "lock.fill" : "lock.open"
    }

    private var lockAccessibilityLabel: String {
        if message.status == .undecryptable { return "Encrypted, could not be decrypted" }
        return peerIsVerified ? "Encrypted, identity verified" : "Encrypted, identity not verified"
    }
}

/// The quoted message shown at the top of a reply.
struct ReplyQuoteView: View {
    let reply: ReplyReference
    let authorName: String
    let textColor: Color

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(textColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(authorName)
                    .font(.caption.bold())
                Text(reply.preview)
                    .font(.caption)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(textColor)
        .padding(6)
        .background(textColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reply to \(authorName): \(reply.preview)")
    }
}
