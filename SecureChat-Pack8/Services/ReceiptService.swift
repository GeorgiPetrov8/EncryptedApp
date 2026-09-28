import Foundation
import Combine
import os

/// Sends and applies delivery/read receipts (feature #3).
@MainActor
final class ReceiptService: ObservableObject {

    private let messageRepository: MessageRepository
    private let authService: AuthService
    private let logger = Logger(subsystem: "com.HyperChat", category: "receipts")

    /// Injected by `AppContainer`, same pattern as `NotePadService.setSendHandler`
    /// — `MessagingService` is constructed after this service and holds a
    /// reference to it, so the dependency can't run through the initializer
    /// without a cycle.
    private var sendHandler: ((ReceiptPayload, Conversation) async throws -> Void)?

    /// Whether to send read receipts.
    ///
    /// Reciprocal by design: turning them off also hides *others'* read
    /// receipts from this user. One-way visibility — seeing who read yours
    /// while hiding your own — is the arrangement people object to, and it is
    /// the reason this toggle exists as a single switch rather than two.
    @Published var sendsReadReceipts: Bool {
        didSet { UserDefaults.standard.set(sendsReadReceipts, forKey: Keys.readReceipts) }
    }

    private enum Keys {
        static let readReceipts = "receipts.sendRead"
    }

    /// Read receipts are batched: opening a conversation with forty unread
    /// messages should cost one envelope, not forty ratchet steps.
    private var pendingReadIds: [String: Set<String>] = [:]
    private var flushTask: Task<Void, Never>?
    private static let flushDelay: Duration = .milliseconds(600)

    init(messageRepository: MessageRepository, authService: AuthService) {
        self.messageRepository = messageRepository
        self.authService = authService
        self.sendsReadReceipts = (UserDefaults.standard.object(forKey: Keys.readReceipts) as? Bool) ?? true
    }

    func setSendHandler(_ handler: @escaping (ReceiptPayload, Conversation) async throws -> Void) {
        sendHandler = handler
    }

    // MARK: Outgoing

    /// Confirms an inbound message was stored.
    ///
    /// Always sent, regardless of the read-receipt preference: "it arrived on
    /// their device" is delivery information the sender is entitled to, and is
    /// something the server already knows (it dequeued the envelope). The
    /// privacy-sensitive signal is *read*, not *delivered*.
    func acknowledgeDelivery(messageId: String, in conversation: Conversation) {
        guard let myUserId = authService.currentUserId else { return }
        try? messageRepository.markDelivered(
            messageId: messageId, ownerUserId: myUserId, at: Date()
        )
        Task {
            await send(
                ReceiptPayload(
                    kind: .delivered,
                    messageIds: [messageId],
                    conversationId: conversation.id,
                    timestamp: Date()
                ),
                in: conversation
            )
        }
    }

    /// Marks messages read locally and schedules a batched receipt.
    func markRead(messageIds: [String], in conversation: Conversation) {
        guard let myUserId = authService.currentUserId, !messageIds.isEmpty else { return }

        // Local state updates even when receipts are disabled — the unread
        // badge is this user's own business and shouldn't depend on whether
        // they tell the sender.
        try? messageRepository.markRead(
            messageIds: messageIds, ownerUserId: myUserId, at: Date()
        )

        guard sendsReadReceipts else { return }
        pendingReadIds[conversation.id, default: []].formUnion(messageIds)
        scheduleFlush(for: conversation)
    }

    private func scheduleFlush(for conversation: Conversation) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            guard !Task.isCancelled else { return }
            await self?.flush(conversation: conversation)
        }
    }

    private func flush(conversation: Conversation) async {
        guard let ids = pendingReadIds.removeValue(forKey: conversation.id), !ids.isEmpty else { return }
        await send(
            ReceiptPayload(
                kind: .read,
                messageIds: Array(ids),
                conversationId: conversation.id,
                timestamp: Date()
            ),
            in: conversation
        )
    }

    private func send(_ payload: ReceiptPayload, in conversation: Conversation) async {
        do {
            try await sendHandler?(payload, conversation)
        } catch {
            // Deliberately not retried and not surfaced. A lost receipt means
            // one tick doesn't appear; the message itself is unaffected. An
            // outbox for receipts would cost more complexity than the failure
            // is worth, and a visible error for "your read receipt didn't
            // send" would be noise.
            logger.debug("Receipt not delivered; the message itself is unaffected")
        }
    }

    // MARK: Incoming

    /// Applies a receipt from the peer to our own sent messages.
    func applyRemote(_ payload: ReceiptPayload, ownerUserId: String) {
        guard sendsReadReceipts || payload.kind == .delivered else {
            // Reciprocity: with read receipts off, incoming read receipts are
            // discarded rather than displayed.
            return
        }
        switch payload.kind {
        case .delivered:
            try? messageRepository.markDelivered(
                messageIds: payload.messageIds, ownerUserId: ownerUserId, at: payload.timestamp
            )
        case .read:
            try? messageRepository.markRead(
                messageIds: payload.messageIds, ownerUserId: ownerUserId, at: payload.timestamp
            )
        }
    }
}
