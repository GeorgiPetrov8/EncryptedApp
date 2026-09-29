import SwiftUI

/// The delivery/read indicator on an outgoing message (feature #3).
///
/// Follows the convention people already know from WhatsApp, because a novel
/// visual language for a familiar concept is a cost with no benefit:
///
///   - clock        — queued, not yet handed to the server
///   - one tick     — the server accepted it
///   - two ticks    — it reached their device
///   - two ticks, tinted — they opened the conversation
///
/// Shown only on your own messages. On incoming ones it would be meaningless
/// (you obviously received it) and would clutter the row.
struct MessageStatusView: View {
    let status: DeliveryStatus
    let deliveredAt: Date?
    let readAt: Date?

    /// Passed in rather than read from the environment so this view can be
    /// previewed and tested against a custom background without a container.
    var tint: Color = .secondary

    var body: some View {
        Group {
            switch resolved {
            case .sending:
                Image(systemName: "clock")
            case .sent:
                Image(systemName: "checkmark")
            case .delivered:
                doubleCheck(tinted: false)
            case .read:
                doubleCheck(tinted: true)
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

    /// The timestamps take precedence over the stored status.
    ///
    /// They can disagree: a receipt may arrive before the send path has
    /// finished writing `.sent`, in which case the row says `.sending` while
    /// `deliveredAt` is already set. Trusting the more advanced of the two
    /// avoids a tick briefly going backwards, which reads as a glitch.
    private var resolved: DeliveryStatus {
        if readAt != nil { return .read }
        if deliveredAt != nil { return .delivered }
        return status
    }

    /// Two overlapping checkmarks rather than a single glyph.
    ///
    /// `checkmark.circle.fill` was the old stand-in, but it reads as
    /// "completed" rather than "delivered", and gave no way to distinguish
    /// delivered from read without a colour change alone — which fails for
    /// colour-blind users and against a custom background.
    private func doubleCheck(tinted: Bool) -> some View {
        HStack(spacing: -3) {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark")
        }
    }

    private var foregroundStyle: Color {
        switch resolved {
        case .read: return .blue
        case .failed, .undecryptable: return .orange
        default: return tint
        }
    }

    /// Spelled out for VoiceOver: the tick count is a purely visual
    /// distinction that doesn't survive being read aloud.
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

// NOTE: `DeliveryStatus` already declares `.delivered` and `.read`, so this
// file adds no cases to it.
//
// Those two are treated as *derived* states: nothing writes them into
// `messages.deliveryStatus`. The send path only ever sets `.sending`, `.sent`
// or `.failed`; receipts are recorded as the `deliveredAt` / `readAt`
// timestamp columns added in migration v9, and `resolved` above reads the
// status back out of them at render time.
//
// The reason for that split is ordering. Receipts arrive over the same
// at-least-once, out-of-order channel as messages, so a `delivered` receipt
// can land after a `read` one. If both wrote to a single status column, the
// later-arriving `delivered` would overwrite `read` and the ticks would go
// backwards. Timestamps are monotonic per kind and `resolved` takes the most
// advanced of the two, so arrival order stops mattering.
