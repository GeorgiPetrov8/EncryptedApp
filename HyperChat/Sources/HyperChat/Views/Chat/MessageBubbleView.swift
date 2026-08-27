import SwiftUI

struct MessageBubbleView: View {
    let message: DisplayMessage
    /// A closed lock means "encrypted and identity verified"; an open lock means
    /// "encrypted, identity not verified" (Bug #2).
    let peerIsVerified: Bool

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 40) }

            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
                bubble

                HStack(spacing: 4) {
                    Image(systemName: lockIcon)
                        .font(.caption2)
                        .accessibilityLabel(lockAccessibilityLabel)
                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                    // FIX (Bug #9): the status icon used to render only for outgoing
                    // messages, so an `.undecryptable` marker — which is always
                    // *incoming* — would never have been visible.
                    if message.isMine || message.status == .undecryptable {
                        Image(systemName: statusIcon)
                            .font(.caption2)
                    }
                }
                .foregroundStyle(message.status == .undecryptable ? .orange : .secondary)
            }

            if !message.isMine { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if message.status == .undecryptable {
            // Distinct treatment: this is a gap in the conversation, not content.
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
        } else {
            HStack(spacing: 6) {
                // FIX (Bug #18): media renders as an icon plus a label. The body of a
                // media message is a key-bearing JSON payload and must never reach a
                // `Text` view.
                if let icon = mediaIcon {
                    Image(systemName: icon)
                        .font(.footnote)
                }
                Text(message.text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.isMine ? Color.accentColor : Color(.secondarySystemBackground))
            .foregroundStyle(message.isMine ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var mediaIcon: String? {
        switch message.contentType {
        case .text: return nil
        case .image: return "photo"
        case .video: return "video"
        case .file: return "paperclip"
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

    private var statusIcon: String {
        switch message.status {
        case .sending: return "clock"
        case .sent: return "checkmark"
        case .delivered: return "checkmark.circle"
        case .read: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        case .undecryptable: return "exclamationmark.octagon"
        }
    }
}
