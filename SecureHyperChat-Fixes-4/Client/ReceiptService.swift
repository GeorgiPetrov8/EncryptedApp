import Foundation
import Combine
import os

/// Sends and applies delivery/read receipts.
///
/// FIX (S38): an incoming receipt only touches messages that are
///   - ours (we sent them),
///   - in the conversation the receipt arrived in,
/// and at most 500 ids per receipt. Before, any contact could mark *any*
/// message id on this device as delivered/read — including ones sent to other
/// people — and a receipt with a huge id list became one huge SQL `IN (...)`.
/// Receipt times can't be in the future either.
@MainActor
final class ReceiptService: ObservableObject {
    private let messageRepository: MessageRepository
    private let authService: AuthService
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "receipts")

    private var sendHandler: ((ReceiptPayload, Conversation) async throws -> Void)?

    let updates = PassthroughSubject<String, Never>()

    @Published var sendsReadReceipts: Bool {
        didSet { UserDefaults.standard.set(sendsReadReceipts, forKey: Keys.readReceipts) }
    }

    private enum Keys {
        static let readReceipts = "receipts.sendRead"
    }

    private static let maxIdsPerReceipt = 500

    private struct Pending {
        var delivered: Set<String> = []
        var read: Set<String> = []
        var conversation: Conversation
    }

    private var pending: [String: Pending] = [:]
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

    func acknowledgeDelivery(messageId: String, in conversation: Conversation) {
        guard authService.currentUserId != nil else { return }
        enqueue(conversation) { $0.delivered.insert(messageId) }
    }

    func markRead(messageIds: [String], in conversation: Conversation) {
        guard let myUserId = authService.currentUserId, !messageIds.isEmpty else { return }
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

        for chunk in Self.chunks(Array(entry.delivered)) {
            await send(ReceiptPayload(kind: .delivered, messageIds: chunk, conversationId: conversationId, timestamp: Date()),
                       in: entry.conversation)
        }
        for chunk in Self.chunks(Array(entry.read)) {
            await send(ReceiptPayload(kind: .read, messageIds: chunk, conversationId: conversationId, timestamp: Date()),
                       in: entry.conversation)
        }
    }

    private static func chunks(_ ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: maxIdsPerReceipt).map {
            Array(ids[$0..<min($0 + maxIdsPerReceipt, ids.count)])
        }
    }

    private func send(_ payload: ReceiptPayload, in conversation: Conversation) async {
        do {
            try await sendHandler?(payload, conversation)
        } catch {
            logger.debug("Receipt not delivered; the message itself is unaffected")
        }
    }

    // MARK: Incoming

    /// - Parameter conversationId: the *locally resolved* conversation id.
    func applyRemote(_ payload: ReceiptPayload, conversationId: String, ownerUserId: String) {
        guard sendsReadReceipts || payload.kind == .delivered else { return }

        let ids = payload.messageIds.prefix(Self.maxIdsPerReceipt).filter { id in
            guard let message = try? messageRepository.fetch(messageId: id, ownerUserId: ownerUserId) else { return false }
            return message.senderId == ownerUserId && message.conversationId == conversationId
        }
        guard !ids.isEmpty else { return }
        let at = min(payload.timestamp, Date())

        switch payload.kind {
        case .delivered:
            try? messageRepository.markDelivered(messageIds: ids, ownerUserId: ownerUserId, at: at)
        case .read:
            try? messageRepository.markDelivered(messageIds: ids, ownerUserId: ownerUserId, at: at)
            try? messageRepository.markRead(messageIds: ids, ownerUserId: ownerUserId, at: at)
        }
        updates.send(conversationId)
    }
}
