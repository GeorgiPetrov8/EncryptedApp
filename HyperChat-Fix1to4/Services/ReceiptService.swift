import Foundation
import Combine
import os

/// Sends and applies delivery/read receipts.
///
/// FIX: this service existed but was never constructed, never called, and
/// incoming receipts were dropped by `MessagingService` as an unknown type.
@MainActor
final class ReceiptService: ObservableObject {

    private let messageRepository: MessageRepository
    private let authService: AuthService
    private let logger = Logger(subsystem: "com.HyperChat", category: "receipts")

    private var sendHandler: ((ReceiptPayload, Conversation) async throws -> Void)?

    /// Emits a conversation id whenever receipts for it were applied, so an
    /// open chat can refresh its ticks.
    let updates = PassthroughSubject<String, Never>()

    /// Whether to send read receipts. Reciprocal: off also hides others' read
    /// receipts from this user.
    @Published var sendsReadReceipts: Bool {
        didSet { UserDefaults.standard.set(sendsReadReceipts, forKey: Keys.readReceipts) }
    }

    private enum Keys {
        static let readReceipts = "receipts.sendRead"
    }

    /// Both kinds are batched per conversation: a backfill of fifty messages, or
    /// opening a chat with fifty unread, costs at most two envelopes.
    private struct Pending {
        var delivered: Set<String> = []
        var read: Set<String> = []
        var conversation: Conversation
    }

    private var pending: [String: Pending] = [:]
    /// FIX: one flush task **per conversation**. A single shared task meant a
    /// receipt for conversation B cancelled the pending flush for A, so A's
    /// receipts waited until something else happened in A.
    private var flushTasks: [String: Task<Void, Never>] = [:]
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

    /// Confirms an inbound message was stored. Always sent — "it arrived" is
    /// something the server already knows; the sensitive signal is *read*.
    func acknowledgeDelivery(messageId: String, in conversation: Conversation) {
        guard authService.currentUserId != nil else { return }
        enqueue(conversation) { $0.delivered.insert(messageId) }
    }

    /// Marks messages read locally and schedules a batched receipt.
    func markRead(messageIds: [String], in conversation: Conversation) {
        guard let myUserId = authService.currentUserId, !messageIds.isEmpty else { return }

        // Local state updates even when receipts are disabled.
        try? messageRepository.markRead(messageIds: messageIds, ownerUserId: myUserId, at: Date())

        guard sendsReadReceipts else { return }
        enqueue(conversation) { $0.read.formUnion(messageIds) }
    }

    private func enqueue(_ conversation: Conversation, _ mutate: (inout Pending) -> Void) {
        var entry = pending[conversation.id] ?? Pending(conversation: conversation)
        mutate(&entry)
        pending[conversation.id] = entry

        flushTasks[conversation.id]?.cancel()
        let conversationId = conversation.id
        flushTasks[conversationId] = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            guard !Task.isCancelled else { return }
            await self?.flush(conversationId: conversationId)
        }
    }

    private func flush(conversationId: String) async {
        flushTasks[conversationId] = nil
        guard let entry = pending.removeValue(forKey: conversationId) else { return }

        if !entry.delivered.isEmpty {
            await send(ReceiptPayload(
                kind: .delivered,
                messageIds: Array(entry.delivered),
                conversationId: conversationId,
                timestamp: Date()
            ), in: entry.conversation)
        }
        if !entry.read.isEmpty {
            await send(ReceiptPayload(
                kind: .read,
                messageIds: Array(entry.read),
                conversationId: conversationId,
                timestamp: Date()
            ), in: entry.conversation)
        }
    }

    private func send(_ payload: ReceiptPayload, in conversation: Conversation) async {
        do {
            try await sendHandler?(payload, conversation)
        } catch {
            // Not retried and not surfaced: a lost receipt means one tick
            // doesn't appear; the message itself is unaffected.
            logger.debug("Receipt not delivered; the message itself is unaffected")
        }
    }

    // MARK: Incoming

    /// Applies a receipt from the peer to our own sent messages.
    ///
    /// - Parameter conversationId: the *locally resolved* conversation id (not
    ///   `payload.conversationId`, which is the sender's view).
    func applyRemote(_ payload: ReceiptPayload, conversationId: String, ownerUserId: String) {
        // Reciprocity: with read receipts off, incoming read receipts are ignored.
        guard sendsReadReceipts || payload.kind == .delivered else { return }

        switch payload.kind {
        case .delivered:
            try? messageRepository.markDelivered(
                messageIds: payload.messageIds, ownerUserId: ownerUserId, at: payload.timestamp
            )
        case .read:
            // A read receipt implies delivery, even if the delivered receipt
            // was lost or hasn't arrived yet.
            try? messageRepository.markDelivered(
                messageIds: payload.messageIds, ownerUserId: ownerUserId, at: payload.timestamp
            )
            try? messageRepository.markRead(
                messageIds: payload.messageIds, ownerUserId: ownerUserId, at: payload.timestamp
            )
        }
        updates.send(conversationId)
    }
}
