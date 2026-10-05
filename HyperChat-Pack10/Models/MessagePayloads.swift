import Foundation

/// A quoted message attached to a reply.
///
/// Carries a snapshot (who wrote it, a short preview) rather than only an id,
/// so the quote still renders if the original is deleted, was never received
/// on this device, or sits far up in history.
struct ReplyReference: Codable, Equatable {
    let messageId: String
    let senderId: String
    let preview: String
    let contentType: MessageContentType

    static let maxPreviewLength = 120
}

/// Plaintext body of a text message.
///
/// Version 1 wraps the text in JSON so a reply can travel with it. Messages
/// from before this change are raw UTF-8; `decode` falls back to that, so old
/// history keeps rendering.
struct TextPayload: Codable, Equatable {
    var v: Int = 1
    let text: String
    let replyTo: ReplyReference?

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

enum MessageEditPolicy {
    /// How long after sending a message can still be edited.
    static let window: TimeInterval = 15 * 60
    /// Extra allowance on the receiving side for clock differences between phones.
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
