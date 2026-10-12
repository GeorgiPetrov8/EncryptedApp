import Foundation

// MARK: - Receipts (feature #3)

/// Confirms that messages reached, or were seen by, the recipient.
///
/// Carries a *batch* of message ids rather than one, because a user opening a
/// conversation with forty unread messages would otherwise emit forty
/// envelopes — forty ratchet steps, forty queue rows, forty pushes.
struct ReceiptPayload: Codable, Equatable {
    enum Kind: String, Codable {
        /// The device received and stored it. Sent automatically.
        case delivered
        /// The user actually looked at the conversation.
        case read
    }

    let kind: Kind
    let messageIds: [String]
    let conversationId: String
    let timestamp: Date
}

// MARK: - Profile (feature #4)

/// A user's display name and avatar, pushed to contacts.
///
/// The avatar travels as an encrypted blob reference — the same mechanism as
/// message media — rather than as bytes inline, so a profile update doesn't
/// put a 200 KB payload through the ratchet.
///
/// Sent peer-to-peer rather than stored on the server, which keeps the server
/// from holding a directory of everyone's face alongside their username. The
/// cost is that a new contact sees a placeholder until the first profile push,
/// which is a fair trade.
struct ProfilePayload: Codable, Equatable {
    let displayName: String?
    /// Server-assigned id of the encrypted avatar blob, as returned by
    /// `uploadMedia`. `nil` clears the avatar.
    let avatarMediaId: String?
    /// The AES key for that blob, base64. Travels inside the ratchet-encrypted
    /// payload, so the server never holds both the blob and its key.
    let avatarKey: Data?
    let updatedAt: Date
}

// MARK: - Invitations (feature #6)

/// A contact request, or the answer to one.
struct InvitePayload: Codable, Equatable {
    enum Kind: String, Codable {
        case request
        case accept
        case decline
    }

    let kind: Kind
    /// Shown to the recipient so a request isn't just an opaque username.
    let senderDisplayName: String?
    /// Optional one-line note — "hi, it's Maria from work". Capped by
    /// `InviteLimits.maxNoteLength` so an invite can't be used as a channel to
    /// send unsolicited messages to someone who hasn't accepted anything.
    let note: String?
    let sentAt: Date
}

enum InviteLimits {
    static let maxNoteLength = 140
}
