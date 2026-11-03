import Foundation
import Combine
import GRDB
import os

/// #12 view-once photo/video and #19 "disappears after reading" — one shared
/// rule set, so the two features can't drift apart.
///
/// Recipient:
///   1. Opening it records `revealedAt` **as soon as the first frame/text is on
///      screen**. From then on it counts as viewed — closing, losing the
///      connection or killing the app doesn't give a second look.
///   2. Closing it (or the next launch, after a crash) "consumes" it: the stored
///      content is wiped, the media row and any cached file are deleted, and the
///      sender is told (`.viewed`). Only a placeholder remains.
/// Sender:
///   3. On `.viewed` the sender's copy is wiped too, so the message is gone on
///      both phones. On `.screenshot` the sender sees "📸 Screenshot taken".
///
/// Never kept anywhere else: excluded from search, gallery, media backup, the
/// backup file, reply quotes, copy/share/save and notifications (see SETUP).
/// Not real DRM — a second camera can always photograph the screen.
@MainActor
final class ConsumeOnViewPolicy: ObservableObject {
    /// Emits a conversation id when a message there changed.
    let updates = PassthroughSubject<String, Never>()

    private let dbQueue: DatabaseQueue
    private let authService: AuthService
    private let mediaCache = MediaCacheStore()
    private var optionsLookup: ((Message) -> SendOptions?)?
    private var sendHandler: ((MessageEventPayload, Conversation) async throws -> Void)?
    private var conversationLookup: ((String) -> Conversation?)?
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "consume")

    init(dbQueue: DatabaseQueue, authService: AuthService) {
        self.dbQueue = dbQueue
        self.authService = authService
    }

    func configure(
        options: @escaping (Message) -> SendOptions?,
        conversation: @escaping (String) -> Conversation?,
        send: @escaping (MessageEventPayload, Conversation) async throws -> Void
    ) {
        optionsLookup = options
        conversationLookup = conversation
        sendHandler = send
    }

    // MARK: Recipient

    /// The first frame / the text is on screen. From now on it counts as viewed.
    func markRevealed(_ message: Message) {
        guard let me = authService.currentUserId, message.senderId != me, message.revealedAt == nil else { return }
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE messages SET revealedAt = ? WHERE ownerUserId = ? AND id = ? AND revealedAt IS NULL",
                           arguments: [Date(), me, message.id])
        }
    }

    /// Gift / secret message opened: remembered, and the sender is told once.
    func markOpened(_ message: Message) {
        guard let me = authService.currentUserId, message.senderId != me, message.revealedAt == nil else { return }
        markRevealed(message)
        updates.send(message.conversationId)
        send(.opened, about: message)
    }

    /// The viewer closed: wipe and tell the sender.
    func consume(_ snapshot: Message) {
        // Re-read: the caller's copy may be stale (already consumed).
        guard let me = authService.currentUserId,
              let message = try? dbQueue.read({ db in
                  try Message.fetchOne(db, key: ["ownerUserId": me, "id": snapshot.id])
              }),
              message.senderId != me, message.consumedAt == nil,
              optionsLookup?(message)?.consumes == true else { return }
        wipe(messageId: message.id, owner: me)
        updates.send(message.conversationId)
        send(.viewed, about: message)
    }

    func reportScreenshot(_ message: Message) {
        guard let me = authService.currentUserId, message.senderId != me,
              optionsLookup?(message)?.consumes == true else { return }
        send(.screenshot, about: message)
    }

    /// At launch: anything opened but not consumed (the app was killed while
    /// viewing) is consumed now.
    func recoverInterrupted() {
        guard let me = authService.currentUserId else { return }
        let opened: [Message] = (try? dbQueue.read { db in
            try Message.fetchAll(db, sql: """
                SELECT * FROM messages
                WHERE ownerUserId = ? AND senderId <> ? AND revealedAt IS NOT NULL AND consumedAt IS NULL
                """, arguments: [me, me])
        }) ?? []
        for message in opened where optionsLookup?(message)?.consumes == true {
            consume(message)
        }
    }

    private func send(_ event: MessageEventPayload.Event, about message: Message) {
        guard let conversation = conversationLookup?(message.conversationId),
              conversation.relationshipState == .accepted else { return }
        let payload = MessageEventPayload(messageId: message.id, event: event, at: Date())
        Task { try? await sendHandler?(payload, conversation) }
    }

    // MARK: Sender

    func applyRemote(_ payload: MessageEventPayload, from senderId: String, conversation: Conversation, ownerUserId: String) {
        guard senderId != ownerUserId,
              let message = try? dbQueue.read({ db in
                  try Message.fetchOne(db, key: ["ownerUserId": ownerUserId, "id": payload.messageId])
              }),
              message.conversationId == conversation.id,
              message.senderId == ownerUserId,
              let options = optionsLookup?(message) ?? (message.consumedAt != nil ? SendOptions(consumeOnView: true) : nil)
        else {
            logger.info("Ignored a message event that didn't match a message we sent")
            return
        }
        switch payload.event {
        case .viewed:
            guard options.consumes, message.consumedAt == nil else { return }
            wipe(messageId: message.id, owner: ownerUserId)
        case .opened:
            guard options.isGift || options.reveal != nil, message.revealedAt == nil else { return }
            try? dbQueue.write { db in
                try db.execute(sql: "UPDATE messages SET revealedAt = ? WHERE ownerUserId = ? AND id = ?",
                               arguments: [min(payload.at, Date()), ownerUserId, message.id])
            }
        case .screenshot:
            guard options.consumes, message.screenshotAt == nil else { return }
            try? dbQueue.write { db in
                try db.execute(sql: "UPDATE messages SET screenshotAt = ? WHERE ownerUserId = ? AND id = ?",
                               arguments: [min(payload.at, Date()), ownerUserId, message.id])
            }
        }
        updates.send(conversation.id)
    }

    // MARK: Wiping

    /// Content → empty, consumedAt set, media rows and cached files deleted.
    /// The options survive only as the `consumedAt` marker.
    private func wipe(messageId: String, owner: String) {
        let mediaIds: [String] = (try? dbQueue.write { db -> [String] in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM media WHERE ownerUserId = ? AND messageId = ?",
                                          arguments: [owner, messageId])
            try db.execute(sql: "DELETE FROM media WHERE ownerUserId = ? AND messageId = ?", arguments: [owner, messageId])
            try db.execute(sql: """
                UPDATE messages SET encryptedContent = ?, consumedAt = ?, revealedAt = COALESCE(revealedAt, ?)
                WHERE ownerUserId = ? AND id = ?
                """, arguments: [Data(), Date(), Date(), owner, messageId])
            return ids
        }) ?? []
        for id in mediaIds {
            if let url = try? mediaCache.url(forMediaId: id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        DecryptedMediaCache.shared.removeAll()
    }
}
