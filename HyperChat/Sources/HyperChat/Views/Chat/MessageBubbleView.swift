import SwiftUI

struct MessageBubbleView: View {
    let message: DisplayMessage
    /// A closed lock means "encrypted and identity verified"; an open lock
    /// means "encrypted, identity not verified".
    let peerIsVerified: Bool
    var mediaLoader: (String) async -> Data? = { _ in nil }

    /// FIX (problem 1): colours come from the chat's resolved appearance, so
    /// incoming bubbles and the time/tick row stay readable on a custom
    /// background. Hard-coded `.primary` / `.secondary` resolve against the
    /// *system* background and can vanish on a dark custom colour.
    @Environment(\.chatAppearance) private var appearance

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 40) }

            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
                bubble
                footer
            }

            if !message.isMine { Spacer(minLength: 40) }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: lockIcon)
                .font(.caption2)
                .accessibilityLabel(lockAccessibilityLabel)
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
        .foregroundStyle(footerColor)
    }

    private var footerColor: Color {
        message.status == .undecryptable ? Color.orange : appearance.secondaryForegroundColor
    }

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
                tint: message.isMine ? .white : .accentColor
            )
            .background(bubbleColor)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            HStack(spacing: 6) {
                if let icon = mediaIcon {
                    Image(systemName: icon)
                        .font(.footnote)
                }
                Text(message.text)
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
        case .text, .image:
            return nil
        case .video:
            return "video"
        case .file:
            return message.mediaType == .audio ? nil : "paperclip"
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
