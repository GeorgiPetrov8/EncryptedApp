import Foundation
import GRDB
import UserNotifications
import os

/// #19 "Send later".
///
/// The message is encrypted and sent **from this phone at the chosen time** —
/// until then it exists only here, as an own message with status `.sending`
/// and `createdAt` = the scheduled time (so it sorts at the bottom of the chat
/// as "Scheduled"). `OutboxService` skips messages whose time hasn't come and
/// sends them once it has.
///
/// Why not hold it on the server: the encryption ratchet would then have to keep
/// that message's key for an unknown time, and a busy chat throws such keys away
/// after two ratchet turns — the message would arrive undecryptable.
///
/// The catch: iOS doesn't let a free app run at an exact time in the background.
/// If the app is open at the time, it goes out right then. If not, a local
/// notification "Tap to send your scheduled message" appears, and it's sent as
/// soon as the app is opened.
@MainActor
final class ScheduledSendService {
    private let dbQueue: DatabaseQueue
    private let authService: AuthService
    private var wake: (() -> Void)?
    private var timer: Task<Void, Never>?
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "scheduled")

    static let maxAhead: TimeInterval = 365 * 24 * 3600
    private static let prefix = "scheduled."

    init(dbQueue: DatabaseQueue, authService: AuthService) {
        self.dbQueue = dbQueue
        self.authService = authService
    }

    /// `wake` = `outboxService.flush()`.
    func configure(wake: @escaping () -> Void) {
        self.wake = wake
    }

    /// Own unsent messages whose time is still ahead.
    func pending() -> [Message] {
        guard let me = authService.currentUserId else { return [] }
        return (try? dbQueue.read { db in
            try Message.fetchAll(db, sql: """
                SELECT * FROM messages
                WHERE ownerUserId = ? AND senderId = ? AND scheduledFor IS NOT NULL
                  AND deliveryStatus = ? AND scheduledFor > ?
                ORDER BY scheduledFor
                """, arguments: [me, me, DeliveryStatus.sending.rawValue, Date()])
        }) ?? []
    }

    /// After scheduling, sending, cancelling, launch and account switch.
    func refresh() {
        timer?.cancel()
        guard let next = pending().first?.scheduledFor else { return }
        let delay = max(1, next.timeIntervalSinceNow + 1)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 24 * 3600) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.wake?()
            self?.refresh()
        }
    }

    func notify(messageId: String, conversationId: String, peerName: String, at date: Date) async {
        guard let me = authService.currentUserId else { return }
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = "Scheduled message"
        content.body = "Tap to send your message to \(SafeText.line(peerName, maxLength: 40) ?? "your contact")."
        content.sound = .default
        content.userInfo = ["kind": "reminder", "ownerUserId": me, "conversationId": conversationId]
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(
            identifier: "\(Self.prefix)\(me).\(messageId)",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        try? await center.add(request)
    }

    /// The message went out (or was cancelled): its notification isn't needed.
    func didSend(messageId: String) {
        guard let me = authService.currentUserId else { return }
        let id = "\(Self.prefix)\(me).\(messageId)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// "Cancel" on a scheduled message: it was never sent, so it's just deleted.
    func cancel(messageId: String) {
        guard let me = authService.currentUserId else { return }
        _ = try? dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM messages WHERE ownerUserId = ? AND id = ? AND senderId = ?
                  AND deliveryStatus = ? AND scheduledFor IS NOT NULL
                """, arguments: [me, messageId, me, DeliveryStatus.sending.rawValue])
        }
        didSend(messageId: messageId)
        refresh()
    }

    static func removeAll(ownerUserId: String) {
        let center = UNUserNotificationCenter.current()
        let prefix = "\(Self.prefix)\(ownerUserId)."
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
    }
}
