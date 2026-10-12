import SwiftUI

/// The delivery/read indicator on an outgoing message.
///
///   - clock      — queued, not yet handed to the server
///   - one tick   — the server accepted it
///   - two ticks  — it reached their device
///   - two ticks, heavy and tinted — they opened the conversation
///
/// "Read" is told apart from "delivered" by **weight as well as colour**: the
/// old version used blue alone, which disappears on a blue background and fails
/// for colour-blind users.
struct MessageStatusView: View {
    let status: DeliveryStatus
    let deliveredAt: Date?
    let readAt: Date?
    /// Colour of the unread states — the text colour on the background.
    var tint: Color = .secondary
    /// Colour of the "read" ticks (see `AppTheme.readTick`).
    var readTint: Color = .blue

    var body: some View {
        Group {
            switch resolved {
            case .sending:
                Image(systemName: "clock")
            case .sent:
                Image(systemName: "checkmark")
            case .delivered:
                doubleCheck
            case .read:
                doubleCheck.fontWeight(.heavy)
            case .failed:
                Image(systemName: "exclamationmark.triangle")
            case .undecryptable:
                Image(systemName: "exclamationmark.octagon")
            }
        }
        .font(.caption2)
        .foregroundStyle(foregroundStyle)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The timestamps take precedence over the stored status: a receipt can
    /// arrive before the send path has written `.sent`, and a tick must not go
    /// backwards.
    private var resolved: DeliveryStatus {
        if readAt != nil { return .read }
        if deliveredAt != nil { return .delivered }
        return status
    }

    private var doubleCheck: some View {
        HStack(spacing: -3) {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark")
        }
    }

    private var foregroundStyle: Color {
        switch resolved {
        case .read: return readTint
        case .failed, .undecryptable: return .orange
        default: return tint
        }
    }

    private var accessibilityLabel: String {
        switch resolved {
        case .sending: return "Sending"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .read: return "Read"
        case .failed: return "Failed to send"
        case .undecryptable: return "Could not be decrypted"
        }
    }
}
