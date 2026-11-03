import Foundation
import UserNotifications
import os

extension Notification.Name {
    /// A tapped reminder asks to open a chat. userInfo: conversationId, ownerUserId.
    static let openConversationRequest = Notification.Name("SecureHyperChat.openConversationRequest")
}

/// #14: "Remind me" on a message — a local notification at a chosen time that
/// opens the chat when tapped.
///
/// A plain reminder, not an alarm: alarms here ring until problems are solved
/// or a word is sent, which is far too much for "remind me to answer this".
/// (Ask if you want the full alarm instead.)
///
/// Privacy: by default the notification shows only the title the user typed;
/// the message text is included only if they switch it on, because it would
/// be readable on the lock screen.
///
/// Identifiers start with `reminder.<owner>.` — the alarm scheduler only ever
/// removes `alarm.` notifications (S37), so the two never interfere.
@MainActor
final class MessageReminderService {
    static let categoryIdentifier = "SHC_REMINDER"
    private static let prefix = "reminder."
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "reminder")

    enum ReminderError: LocalizedError {
        case notAllowed
        case inThePast

        var errorDescription: String? {
            switch self {
            case .notAllowed: return "Allow notifications for SecureHyperChat in Settings to get reminders."
            case .inThePast: return "Pick a time in the future."
            }
        }
    }

    func schedule(
        ownerUserId: String,
        conversationId: String,
        messageId: String,
        title: String,
        body: String?,
        at date: Date
    ) async throws {
        guard date > Date().addingTimeInterval(30) else { throw ReminderError.inThePast }

        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        guard await center.notificationSettings().authorizationStatus == .authorized else {
            throw ReminderError.notAllowed
        }

        let content = UNMutableNotificationContent()
        content.title = SafeText.line(title, maxLength: 80) ?? "Reminder"
        content.body = body.flatMap { SafeText.line($0, maxLength: 160) } ?? "Tap to open the chat."
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = "reminder.\(conversationId)"
        content.userInfo = [
            "kind": "reminder",
            "ownerUserId": ownerUserId,
            "conversationId": conversationId,
            "messageId": messageId,
        ]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(
            identifier: "\(Self.prefix)\(ownerUserId).\(UUID().uuidString)",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        try await center.add(request)
        logger.info("Reminder scheduled")
    }

    /// Account deletion: removes this account's reminders, scheduled and shown.
    static func removeAll(ownerUserId: String) {
        let center = UNUserNotificationCenter.current()
        let prefix = "\(Self.prefix)\(ownerUserId)."
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
        center.getDeliveredNotifications { notes in
            center.removeDeliveredNotifications(withIdentifiers: notes.map(\.request.identifier).filter { $0.hasPrefix(prefix) })
        }
    }
}

/// Carries a tapped reminder to the chats list, also on a cold start (the tap
/// arrives before the list exists, so it's kept until the list asks for it).
@MainActor
final class ReminderRouter {
    static let shared = ReminderRouter()
    private var pending: (conversationId: String, ownerUserId: String)?

    /// From `AppDelegate`. Returns true if the notification was a reminder.
    @discardableResult
    func handle(userInfo: [AnyHashable: Any]) -> Bool {
        guard (userInfo["kind"] as? String) == "reminder",
              let conversationId = userInfo["conversationId"] as? String,
              let ownerUserId = userInfo["ownerUserId"] as? String else { return false }
        pending = (conversationId, ownerUserId)
        NotificationCenter.default.post(
            name: .openConversationRequest, object: nil,
            userInfo: ["conversationId": conversationId, "ownerUserId": ownerUserId]
        )
        return true
    }

    /// The chats list calls this when it appears.
    func takePending() -> (conversationId: String, ownerUserId: String)? {
        defer { pending = nil }
        return pending
    }

    func clear() { pending = nil }
}
