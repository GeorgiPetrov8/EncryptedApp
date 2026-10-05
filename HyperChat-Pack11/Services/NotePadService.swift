import Foundation
import Combine
import os

/// Orchestrates the shared notepad: local edits, the merge, and transmission
/// through the same encrypted channel chat messages use.
@MainActor
final class NotePadService: ObservableObject {
    @Published private(set) var itemsByConversation: [String: [NotePadItem]] = [:]

    private let repository: NotePadRepository
    private let conversationRepository: ConversationRepository
    private let authService: AuthService
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.HyperChat", category: "notePad")

    private var sendHandler: ((NotePadOperation, Conversation) async throws -> Void)?
    private var flushing: Set<String> = []

    init(
        repository: NotePadRepository,
        conversationRepository: ConversationRepository,
        authService: AuthService,
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.conversationRepository = conversationRepository
        self.authService = authService
        self.defaults = defaults
    }

    func setSendHandler(_ handler: @escaping (NotePadOperation, Conversation) async throws -> Void) {
        sendHandler = handler
    }

    func items(for conversationId: String) -> [NotePadItem] {
        itemsByConversation[conversationId] ?? []
    }

    func loadItems(for conversation: Conversation) {
        guard let myUserId = authService.currentUserId else { return }
        refreshPublishedState(ownerUserId: myUserId, conversationId: conversation.id)
    }

    // MARK: Local edits

    func addItem(text: String, in conversation: Conversation) async {
        guard let myUserId = authService.currentUserId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await apply(
            NotePadOperation(itemId: UUID().uuidString, text: trimmed, isDone: false, isDeleted: false,
                             updatedAt: Date(), updatedBy: myUserId),
            in: conversation, ownerUserId: myUserId
        )
    }

    func toggleItem(_ item: NotePadItem, in conversation: Conversation) async {
        await edit(item, in: conversation) { $0.isDone.toggle() }
    }

    func updateText(_ item: NotePadItem, newText: String, in conversation: Conversation) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await edit(item, in: conversation) { $0.text = trimmed }
    }

    func deleteItem(_ item: NotePadItem, in conversation: Conversation) async {
        // Tombstone, not a hard delete — see `NotePadItem.isDeleted`.
        await edit(item, in: conversation) { $0.isDeleted = true }
    }

    /// Applies a change to the *current* stored item (not the possibly stale
    /// copy the view holds) with a timestamp that is guaranteed to win.
    private func edit(_ item: NotePadItem, in conversation: Conversation, _ change: (inout NotePadItem) -> Void) async {
        guard let myUserId = authService.currentUserId else { return }
        let current = (try? repository.fetchAll(ownerUserId: myUserId, conversationId: conversation.id))?
            .first { $0.itemId == item.itemId } ?? item
        var updated = current
        change(&updated)
        await apply(
            NotePadOperation(itemId: updated.itemId, text: updated.text, isDone: updated.isDone,
                             isDeleted: updated.isDeleted,
                             updatedAt: Self.timestamp(after: current.updatedAt),
                             updatedBy: myUserId),
            in: conversation, ownerUserId: myUserId
        )
    }

    /// FIX (clock skew): a new edit is always stamped after the version it
    /// replaces.
    ///
    /// Conflicts are decided by the latest `updatedAt`. When the other phone's
    /// clock ran fast, its edits carried future times and beat every edit
    /// made here until this clock caught up — your own change was silently
    /// ignored, possibly for hours. Stamping at least 1 ms past the current
    /// version means a deliberate edit always wins, and both phones still
    /// agree because they compare the same values. (Clamping times on
    /// arrival instead would make the two phones disagree.)
    static func timestamp(after previous: Date, now: Date = Date()) -> Date {
        max(now, previous.addingTimeInterval(0.001))
    }

    private func apply(_ operation: NotePadOperation, in conversation: Conversation, ownerUserId: String) async {
        let candidate = NotePadItem(
            ownerUserId: ownerUserId,
            conversationId: conversation.id,
            itemId: operation.itemId,
            text: operation.text,
            isDone: operation.isDone,
            isDeleted: operation.isDeleted,
            updatedAt: operation.updatedAt,
            updatedBy: operation.updatedBy
        )

        guard let result = try? repository.upsertIfNewer(
            ownerUserId: ownerUserId, conversationId: conversation.id, candidate: candidate
        ) else {
            logger.error("Failed to persist local notepad edit")
            return
        }
        refreshPublishedState(ownerUserId: ownerUserId, conversationId: conversation.id)
        guard result.changed else { return }

        // FIX (outbox): recorded as unsent *before* trying, cleared only on
        // success. Edits made offline, before an invitation was accepted, or
        // while the server was down are retried on reconnect and on opening
        // the pad, instead of being lost.
        markPending(itemId: operation.itemId, version: operation.updatedAt,
                    conversationId: conversation.id, ownerUserId: ownerUserId)
        await send(operation, in: conversation, ownerUserId: ownerUserId)
    }

    private func send(_ operation: NotePadOperation, in conversation: Conversation, ownerUserId: String) async {
        do {
            try await sendHandler?(operation, conversation)
            clearPending(itemId: operation.itemId, version: operation.updatedAt,
                         conversationId: conversation.id, ownerUserId: ownerUserId)
        } catch {
            logger.info("Notepad edit not sent yet; it will be retried")
        }
    }

    // MARK: Remote edits

    func applyRemoteOperation(_ operation: NotePadOperation, conversationId: String, ownerUserId: String) {
        let candidate = NotePadItem(
            ownerUserId: ownerUserId,
            conversationId: conversationId,
            itemId: operation.itemId,
            text: operation.text,
            isDone: operation.isDone,
            isDeleted: operation.isDeleted,
            updatedAt: operation.updatedAt,
            updatedBy: operation.updatedBy
        )
        guard (try? repository.upsertIfNewer(
            ownerUserId: ownerUserId, conversationId: conversationId, candidate: candidate
        )) != nil else {
            logger.error("Failed to merge remote notepad operation")
            return
        }
        refreshPublishedState(ownerUserId: ownerUserId, conversationId: conversationId)
    }

    // MARK: Outbox

    /// Sends this conversation's unsent edits (current state of each item).
    ///
    /// FIX: replaces `resyncOwnItems`, which re-sent *every* item — including
    /// the other person's — each time the pad was opened: one encrypted
    /// envelope per item per open, for nothing.
    func flushPending(in conversation: Conversation) async {
        guard let myUserId = authService.currentUserId,
              !flushing.contains(conversation.id) else { return }
        let pending = loadPending(ownerUserId: myUserId)[conversation.id] ?? [:]
        guard !pending.isEmpty else { return }

        flushing.insert(conversation.id)
        defer { flushing.remove(conversation.id) }

        let items = (try? repository.fetchAll(ownerUserId: myUserId, conversationId: conversation.id)) ?? []
        for item in items where pending[item.itemId] != nil {
            let operation = NotePadOperation(
                itemId: item.itemId, text: item.text, isDone: item.isDone, isDeleted: item.isDeleted,
                updatedAt: item.updatedAt, updatedBy: item.updatedBy
            )
            await send(operation, in: conversation, ownerUserId: myUserId)
        }
        // Items that no longer exist locally have nothing left to send.
        let existing = Set(items.map(\.itemId))
        for itemId in pending.keys where !existing.contains(itemId) {
            dropPending(itemId: itemId, conversationId: conversation.id, ownerUserId: myUserId)
        }
    }

    /// Flushes every conversation with unsent edits (on reconnect / launch).
    func flushAllPending() async {
        guard let myUserId = authService.currentUserId else { return }
        for conversationId in loadPending(ownerUserId: myUserId).keys {
            guard let conversation = try? conversationRepository.fetch(id: conversationId, ownerUserId: myUserId) else {
                dropConversation(conversationId, ownerUserId: myUserId)
                continue
            }
            await flushPending(in: conversation)
        }
    }

    /// Kept so older call sites compile; now only sends unsent edits.
    func resyncOwnItems(in conversation: Conversation) async {
        await flushPending(in: conversation)
    }

    // Stored as [conversationId: [itemId: version]] per account. The version
    // check on clear means a newer edit made while an older one was in
    // flight isn't marked as sent by mistake.
    private typealias Pending = [String: [String: Double]]

    private func pendingKey(_ owner: String) -> String { "notepad.pending.\(owner)" }

    private func loadPending(ownerUserId: String) -> Pending {
        guard let data = defaults.data(forKey: pendingKey(ownerUserId)),
              let decoded = try? JSONDecoder().decode(Pending.self, from: data) else { return [:] }
        return decoded
    }

    private func savePending(_ pending: Pending, ownerUserId: String) {
        let cleaned = pending.filter { !$0.value.isEmpty }
        defaults.set(try? JSONEncoder().encode(cleaned), forKey: pendingKey(ownerUserId))
    }

    private func markPending(itemId: String, version: Date, conversationId: String, ownerUserId: String) {
        var pending = loadPending(ownerUserId: ownerUserId)
        pending[conversationId, default: [:]][itemId] = version.timeIntervalSince1970
        savePending(pending, ownerUserId: ownerUserId)
    }

    private func clearPending(itemId: String, version: Date, conversationId: String, ownerUserId: String) {
        var pending = loadPending(ownerUserId: ownerUserId)
        guard let stored = pending[conversationId]?[itemId],
              stored <= version.timeIntervalSince1970 else { return }
        pending[conversationId]?[itemId] = nil
        savePending(pending, ownerUserId: ownerUserId)
    }

    private func dropPending(itemId: String, conversationId: String, ownerUserId: String) {
        var pending = loadPending(ownerUserId: ownerUserId)
        pending[conversationId]?[itemId] = nil
        savePending(pending, ownerUserId: ownerUserId)
    }

    private func dropConversation(_ conversationId: String, ownerUserId: String) {
        var pending = loadPending(ownerUserId: ownerUserId)
        pending[conversationId] = nil
        savePending(pending, ownerUserId: ownerUserId)
    }

    // MARK: State

    private func refreshPublishedState(ownerUserId: String, conversationId: String) {
        let loaded = (try? repository.fetchAll(ownerUserId: ownerUserId, conversationId: conversationId)) ?? []
        itemsByConversation[conversationId] = loaded
    }

    func clearInMemoryState() {
        itemsByConversation.removeAll()
    }

    func deleteAllOnDisk(ownerUserId: String) throws {
        try repository.deleteAll(ownerUserId: ownerUserId)
        defaults.removeObject(forKey: pendingKey(ownerUserId))
        itemsByConversation.removeAll()
    }
}
