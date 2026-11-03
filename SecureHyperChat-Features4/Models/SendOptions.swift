import Foundation

/// #12 and #19: how a message is delivered and shown.
///
/// Travels **inside** the encrypted payload (`TextPayload.options`,
/// `MediaKeyPayload.options`), so the server never sees it. An older app version
/// ignores the field and shows the message normally — that's why every option
/// here is a courtesy the *recipient's app* enforces, not a cryptographic
/// guarantee. The UI says so where it matters.
struct SendOptions: Codable, Equatable {
    enum Reveal: String, Codable, CaseIterable, Identifiable {
        /// Press and hold to see it.
        case hold
        /// Solve a 3×3 sliding puzzle to see it.
        case puzzle
        var id: String { rawValue }
        var title: String { self == .hold ? "Hold to reveal" : "Slide puzzle" }
    }

    /// #19 secret message.
    var reveal: Reveal?
    /// #19 gift wrap.
    var gift: Bool?
    /// #12 view-once (photo/video) and #19 "disappears after reading" (text).
    var consumeOnView: Bool?
    /// #19 locked until this date.
    var unlocksAt: Date?

    static let none = SendOptions()
    static let maxLockDuration: TimeInterval = 5 * 365 * 24 * 3600

    var isEmpty: Bool { reveal == nil && gift != true && consumeOnView != true && unlocksAt == nil }
    var isGift: Bool { gift == true }
    var consumes: Bool { consumeOnView == true }

    /// Options from another phone: drop what doesn't make sense, cap the lock.
    func validated(contentType: MessageContentType, now: Date) -> SendOptions? {
        var copy = self
        if let unlocksAt = copy.unlocksAt {
            copy.unlocksAt = unlocksAt <= now ? nil : min(unlocksAt, now.addingTimeInterval(Self.maxLockDuration))
        }
        // View-once / disappearing: text, photos and videos only.
        if copy.consumes, !(contentType == .text || contentType == .image || contentType == .video) {
            copy.consumeOnView = nil
        }
        if copy.gift == false { copy.gift = nil }
        if copy.consumeOnView == false { copy.consumeOnView = nil }
        return copy.isEmpty ? nil : copy
    }

    /// Text shown wherever the content must not leak: chat list, reply quotes,
    /// notifications, search. Nil = no masking needed.
    func maskedPreview(contentType: MessageContentType, consumed: Bool, unlocked: Bool) -> String? {
        if consumes {
            if consumed { return contentType == .text ? "💨 Message disappeared" : "👁 Opened" }
            return contentType == .text ? "💨 Disappearing message" : (contentType == .video ? "👁 View-once video" : "👁 View-once photo")
        }
        if let unlocksAt, !unlocked {
            return "🔒 Opens \(unlocksAt.formatted(date: .abbreviated, time: .shortened))"
        }
        if isGift { return "🎁 Gift" }
        if reveal != nil { return "🧩 Secret message" }
        return nil
    }
}

/// #12 / #19: what happened to one of *your* messages on the other phone.
/// Sent as the control message `.messageEvent` (server allow-list: 'messageEvent').
struct MessageEventPayload: Codable, Equatable {
    enum Event: String, Codable {
        /// A view-once / disappearing message was opened (and is now gone).
        case viewed
        /// A gift or secret message was opened.
        case opened
        /// A screenshot was taken while a view-once / disappearing message was open.
        case screenshot
    }

    let messageId: String
    let event: Event
    let at: Date
}
