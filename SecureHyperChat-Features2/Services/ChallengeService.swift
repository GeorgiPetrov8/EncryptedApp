import Foundation
import Combine
import GRDB
import os

/// #20: challenge status — who may change it, and keeping both phones in step.
///
/// Rules:
///   - only the person who **received** the card can accept, decline or mark it
///     done; the sender just sees the status;
///   - the status only moves forward (`ChallengeStatus.canMove`), so an old or
///     repeated update can't undo anything;
///   - an update from the other phone is applied only if it is about a
///     challenge message in the same chat that *we* sent.
///
/// "Spicy" cards are off by default and need an 18+ confirmation in Settings.
@MainActor
final class ChallengeService: ObservableObject {
    /// Emits a conversation id when a status changed.
    let updates = PassthroughSubject<String, Never>()

    @Published var spicyEnabled: Bool {
        didSet { UserDefaults.standard.set(spicyEnabled, forKey: Keys.spicy) }
    }

    private let dbQueue: DatabaseQueue
    private let messageRepository: MessageRepository
    private let authService: AuthService
    /// Decrypts a stored message's challenge card (set by AppContainer).
    private var cardLookup: ((Message) -> ChallengeCard?)?
    private var sendHandler: ((ChallengeUpdatePayload, Conversation) async throws -> Void)?
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "challenge")

    private enum Keys {
        static let spicy = "challenges.spicyEnabled"
    }

    init(dbQueue: DatabaseQueue, messageRepository: MessageRepository, authService: AuthService) {
        self.dbQueue = dbQueue
        self.messageRepository = messageRepository
        self.authService = authService
        self.spicyEnabled = UserDefaults.standard.bool(forKey: Keys.spicy)
    }

    func configure(
        cardLookup: @escaping (Message) -> ChallengeCard?,
        send: @escaping (ChallengeUpdatePayload, Conversation) async throws -> Void
    ) {
        self.cardLookup = cardLookup
        self.sendHandler = send
    }

    var availableCategories: [ChallengeCategory] {
        ChallengeCategory.allCases.filter { $0 != .spicy || spicyEnabled }
    }

    // MARK: Reading

    func status(messageId: String) -> ChallengeStatus {
        guard let me = authService.currentUserId else { return .sent }
        let state = try? dbQueue.read { db in
            try ChallengeState.fetchOne(db, key: ["ownerUserId": me, "messageId": messageId])
        }
        return state?.status ?? .sent
    }

    /// Statuses of the challenges in a page of messages.
    func statuses(messageIds: [String]) -> [String: ChallengeStatus] {
        guard let me = authService.currentUserId, !messageIds.isEmpty else { return [:] }
        let rows = (try? dbQueue.read { db in
            try ChallengeState
                .filter(Column("ownerUserId") == me)
                .filter(messageIds.contains(Column("messageId")))
                .fetchAll(db)
        }) ?? []
        return Dictionary(rows.map { ($0.messageId, $0.status) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Responding (receiver)

    func respond(messageId: String, status next: ChallengeStatus, in conversation: Conversation) async throws {
        guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
        guard let message = try messageRepository.fetch(messageId: messageId, ownerUserId: me),
              message.conversationId == conversation.id,
              message.senderId != me,
              cardLookup?(message) != nil
        else { return }

        let now = Date()
        guard try save(owner: me, conversationId: conversation.id, messageId: messageId, status: next, at: now) else { return }
        updates.send(conversation.id)
        try await sendHandler?(ChallengeUpdatePayload(messageId: messageId, status: next, at: now), conversation)
    }

    // MARK: Receiving (sender's phone)

    func applyRemote(_ payload: ChallengeUpdatePayload, from senderId: String, conversation: Conversation, ownerUserId: String) {
        guard let message = try? messageRepository.fetch(messageId: payload.messageId, ownerUserId: ownerUserId),
              message.conversationId == conversation.id,
              message.senderId == ownerUserId,      // we sent the card…
              senderId != ownerUserId,              // …and the other person answered
              cardLookup?(message) != nil
        else {
            logger.info("Ignored a challenge update that didn't match a challenge we sent")
            return
        }
        let at = min(payload.at, Date().addingTimeInterval(5 * 60))
        if (try? save(owner: ownerUserId, conversationId: conversation.id, messageId: payload.messageId, status: payload.status, at: at)) == true {
            updates.send(conversation.id)
        }
    }

    /// Saves if the move is allowed from the stored status. Returns whether it changed.
    private func save(owner: String, conversationId: String, messageId: String, status next: ChallengeStatus, at: Date) throws -> Bool {
        try dbQueue.write { db in
            let current = try ChallengeState.fetchOne(db, key: ["ownerUserId": owner, "messageId": messageId])
            guard (current?.status ?? .sent).canMove(to: next) else { return false }
            try ChallengeState(
                ownerUserId: owner,
                conversationId: conversationId,
                messageId: messageId,
                status: next,
                updatedAt: at
            ).save(db)
            return true
        }
    }

    func deleteAll(ownerUserId: String) {
        _ = try? dbQueue.write { db in
            try ChallengeState.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
        }
    }
}
