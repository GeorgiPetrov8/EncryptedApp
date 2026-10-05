import SwiftUI

struct MessageBubbleView: View {
    let message: DisplayMessage
    let peerIsVerified: Bool
    var mediaLoader: (String) async -> Data? = { _ in nil }
    var onReply: () -> Void = {}
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    var onQuoteTap: (String) -> Void = { _ in }

    @Environment(\.chatAppearance) private var appearance

    @State private var swipeOffset: CGFloat = 0
    @State private var swipeArmed = false

    /// How far the bubble must be dragged to trigger a reply.
    private let replyThreshold: CGFloat = 60
    /// Swipe toward the middle of the screen: right for their messages, left
    /// for yours. Flip the sign here to make both swipe right instead.
    private var swipeSign: CGFloat { message.isMine ? -1 : 1 }

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 40) }

            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
                bubble
                    .contextMenu { contextMenu }
                footer
            }
            .offset(x: swipeOffset)
            .background(alignment: message.isMine ? .trailing : .leading) { replyHint }

            if !message.isMine { Spacer(minLength: 40) }
        }
        // Simultaneous, so vertical scrolling still works; only a clearly
        // horizontal drag moves the bubble.
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
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.footnote)
            .foregroundStyle(appearance.foregroundColor)
            .padding(8)
            .background(Circle().fill(appearance.incomingBubbleColor))
            .opacity(min(1, abs(swipeOffset) / replyThreshold))
            .scaleEffect(swipeArmed ? 1.15 : 0.9)
            .offset(x: message.isMine ? 36 : -36)
    }

    // MARK: Long-press menu

    @ViewBuilder
    private var contextMenu: some View {
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
        if message.canEdit {
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete for me", systemImage: "trash")
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
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.orange, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        } else if message.contentType == .image {
            MediaMessageView(messageId: message.id, mediaLoader: mediaLoader)
        } else if message.contentType == .file, message.mediaType == .audio {
            VoiceMessageBubble(
                duration: message.voiceDuration ?? 0,
                waveform: message.voiceWaveform ?? [],
                audioData: { await mediaLoader(message.id) },
                tint: message.isMine ? .white : appearance.foregroundColor
            )
            .background(bubbleColor)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                HStack(spacing: 6) {
                    if let icon = mediaIcon {
                        Image(systemName: icon)
                            .font(.footnote)
                    }
                    Text(message.text)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bubbleColor)
            .foregroundStyle(textColor)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var bubbleColor: Color {
        message.isMine ? Color.accentColor : appearance.incomingBubbleColor
    }

    private var textColor: Color {
        message.isMine ? Color.white : appearance.foregroundColor
    }

    private var mediaIcon: String? {
        switch message.contentType {
        case .text, .image: return nil
        case .video: return "video"
        case .file: return message.mediaType == .audio ? nil : "paperclip"
        }
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
