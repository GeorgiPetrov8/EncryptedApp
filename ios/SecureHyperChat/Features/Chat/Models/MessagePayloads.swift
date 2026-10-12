import Foundation

/// A quoted message attached to a reply.
struct ReplyReference: Codable, Equatable {
    let messageId: String
    let senderId: String
    let preview: String
    let contentType: MessageContentType

    static let maxPreviewLength = 120
}

/// A GIF from a GIF provider (KLIPY or GIPHY), sent as a link.
///
/// The GIF is **not** re-uploaded: both providers require their media to be
/// loaded directly from the URLs they return. The URL travels inside the
/// end-to-end encrypted message, so our server never sees it.
struct GIFAttachment: Codable, Equatable {
    let id: String
    /// Full-size GIF.
    let url: URL
    /// Smaller rendition for the chat bubble (falls back to `url`).
    let previewURL: URL?
    let width: Int
    let height: Int
    /// "klipy" or "giphy" — shown in the "tap to load" placeholder.
    let provider: String

    var displayURL: URL { previewURL ?? url }

    var providerName: String {
        provider.lowercased() == "giphy" ? "GIPHY" : "KLIPY"
    }

    /// Only HTTPS URLs from known GIF providers are ever loaded.
    ///
    /// Without this check a contact could send a "GIF" pointing at their own
    /// server and learn your IP address the moment the GIF loads.
    var isTrustedSource: Bool {
        [url, previewURL].compactMap { $0 }.allSatisfy(Self.isTrusted)
    }

    private static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return trustedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let trustedDomains = ["klipy.com", "giphy.com"]
}

/// Plaintext body of a text message.
///
/// Version 1 wraps the text in JSON so a reply (and now a GIF) can travel
/// with it. Older messages are raw UTF-8; `decode` falls back to that.
/// Older app versions ignore the `gif` field and show the text ("🎞️ GIF").
struct TextPayload: Codable, Equatable {
    var v: Int = 1
    let text: String
    let replyTo: ReplyReference?
    var gif: GIFAttachment? = nil

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> TextPayload? {
        if let payload = try? JSONDecoder().decode(TextPayload.self, from: data), payload.v >= 1 {
            return payload
        }
        guard let legacy = String(data: data, encoding: .utf8) else { return nil }
        return TextPayload(text: legacy, replyTo: nil)
    }
}

/// Replaces the text of a message the sender already sent.
struct EditPayload: Codable, Equatable {
    let messageId: String
    let text: String
    let editedAt: Date
}

/// An emoji reaction to a message. `emoji == nil` removes the reaction.
/// One reaction per person per message, like WhatsApp.
struct ReactionPayload: Codable, Equatable {
    let messageId: String
    let emoji: String?
    let reactedAt: Date

    static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    /// Exactly one emoji (one grapheme cluster, so skin tones and flags work).
    static func isValidEmoji(_ value: String) -> Bool {
        guard value.count == 1, value.utf8.count <= 32 else { return false }
        return value.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0xFF)
        }
    }
}

enum MessageEditPolicy {
    static let window: TimeInterval = 15 * 60
    static let receiveGrace: TimeInterval = 5 * 60
}

enum MessageEditError: LocalizedError {
    case notEditable
    case windowExpired
    case empty

    var errorDescription: String? {
        switch self {
        case .notEditable: return "This message can't be edited."
        case .windowExpired: return "Messages can only be edited for 15 minutes after sending."
        case .empty: return "A message can't be empty."
        }
    }
}

enum ReactionError: LocalizedError {
    case notReactable
    case invalidEmoji

    var errorDescription: String? {
        switch self {
        case .notReactable: return "You can't react to this message."
        case .invalidEmoji: return "That isn't a single emoji."
        }
    }
}
