import Foundation
import Combine
import os

/// Orchestrates the shared notepad: local mutations, the CRDT merge, and
/// (via an injected send handler) transmission through the same encrypted
/// channel chat messages use.
///
/// `@MainActor` + `ObservableObject` for the same reason `MessagingService`
/// is: SwiftUI views read `@Published` state directly, and every call site
/// that touches the database or crypto layer here is already expected to be
/// on the main actor by those layers' own isolation.
@MainActor
final class NotePadService: ObservableObject {
    /// Keyed by `conversationId`. A dictionary rather than one flat array
    /// because a device can have many conversations, each with its own
    /// independent pad, and a view for conversation A must never flash
    /// conversation B's items during the moment between "an envelope for B
    /// arrived" and "this dictionary finishes updating."
    @Published private(set) var itemsByConversation: [String: [NotePadItem]] = [:]

    private let repository: NotePadRepository
    private let authService: AuthService
    private let logger = Logger(subsystem: "com.HyperChat", category: "notePad")

    /// FIX: breaks a construction-order dependency cycle, the same pattern
    /// already used by `AuthService.setLogoutHandler` and by
    /// `SessionTokenStore` existing independently of both
    /// `AuthService`/`RealAPIClient`.
    ///
    /// `NotePadService` needs to *transmit* an encrypted envelope, which is
    /// `MessagingService`'s job. `MessagingService` needs to *hold* a
    /// `NotePadService` so `handleIncoming` can route `.notePad` envelopes
    /// to it. Neither can be the other's constructor parameter without a
    /// cycle. `AppContainer` constructs both, then wires this closure.
    private var sendHandler: ((NotePadOperation, Conversation) async throws -> Void)?

    init(repository: NotePadRepository, authService: AuthService) {
        self.repository = repository
        self.authService = authService
    }

    func setSendHandler(_ handler: @escaping (NotePadOperation, Conversation) async throws -> Void) {
        sendHandler = handler
    }

    func items(for conversationId: String) -> [NotePadItem] {
        itemsByConversation[conversationId] ?? []
    }

    /// Call when a `NotePadView` appears — populates `itemsByConversation`
    /// for that conversation from disk so the view has something to show
    /// before any network activity happens (this is a local-first feature;
    /// the pad works fully offline, the same as everything else in this app).
    func loadItems(for conversation: Conversation) {
        guard let myUserId = authService.currentUserId else { return }
        refreshPublishedState(ownerUserId: myUserId, conversationId: conversation.id)
    }

    // MARK: Local mutations
    //
    // Every one of these funnels through `apply`, which runs the exact same
    // merge-then-maybe-transmit path a *remote* operation takes through
    // `applyRemoteOperation`. "I edited it myself" and "my peer edited it"
    // are the same code path with a different origin, not two paths that
    // could quietly drift apart from each other over time.

    func addItem(text: String, in conversation: Conversation) async {
        guard let myUserId = authService.currentUserId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let op = NotePadOperation(
            itemId: UUID().uuidString,
            text: trimmed,
            isDone: false,
            isDeleted: false,
            updatedAt: Date(),
            updatedBy: myUserId
        )
        await apply(op, in: conversation, ownerUserId: myUserId)
    }

    func toggleItem(_ item: NotePadItem, in conversation: Conversation) async {
        guard let myUserId = authService.currentUserId else { return }
        let op = NotePadOperation(
            itemId: item.itemId,
            text: item.text,
            isDone: !item.isDone,
            isDeleted: item.isDeleted,
            updatedAt: Date(),
            updatedBy: myUserId
        )
        await apply(op, in: conversation, ownerUserId: myUserId)
    }

    func updateText(_ item: NotePadItem, newText: String, in conversation: Conversation) async {
        guard let myUserId = authService.currentUserId else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let op = NotePadOperation(
            itemId: item.itemId,
            text: trimmed,
            isDone: item.isDone,
            isDeleted: item.isDeleted,
            updatedAt: Date(),
            updatedBy: myUserId
        )
        await apply(op, in: conversation, ownerUserId: myUserId)
    }

    func deleteItem(_ item: NotePadItem, in conversation: Conversation) async {
        guard let myUserId = authService.currentUserId else { return }
        // Tombstone, not a hard delete — see `NotePadItem.isDeleted`'s doc
        // comment for why a hard delete would break convergence against a
        // concurrently in-flight edit to the same item from the peer.
        let op = NotePadOperation(
            itemId: item.itemId,
            text: item.text,
            isDone: item.isDone,
            isDeleted: true,
            updatedAt: Date(),
            updatedBy: myUserId
        )
        await apply(op, in: conversation, ownerUserId: myUserId)
    }

    /// Applies a locally-originated operation optimistically — the checkbox
    /// flips instantly regardless of whether the peer is even reachable
    /// right now, the same offline-first behaviour every other part of this
    /// app already has — then attempts to transmit it.
    ///
    /// A transmit failure here is not retried by anything: the operation is
    /// durably merged into the local pad (so the user's own view of it is
    /// never lost), but if `sendHandler` throws — e.g. no network at the
    /// moment — the peer simply doesn't receive this particular edit until
    /// the next successful one for the same item arrives and (being the
    /// full item state, not a delta) happens to carry a still-current
    /// picture forward. A dedicated outbox with automatic retry would close
    /// that gap for real; see this pack's `CHANGES-NotePad.md` for why it's
    /// out of scope here.
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

        // If the merge was a no-op (this edit lost to a newer one already
        // on disk — possible if a remote op for the same item arrived a
        // moment earlier), there's nothing new to tell the peer about.
        guard result.changed else { return }

        do {
            try await sendHandler?(operation, conversation)
        } catch {
            logger.error("Failed to transmit notepad operation; local state is still correct")
        }
    }

    /// Called by `MessagingService.handleIncoming` for an inbound
    /// `.notePad` envelope, after Double Ratchet decryption but before
    /// anything resembling chat-message bookkeeping happens — a notepad
    /// sync never becomes a `Message` row (see `EnvelopePayloadKind`'s doc
    /// comment for why), so there is nothing here that looks like
    /// `incomingMessage` publishing; the UI refresh is `itemsByConversation`
    /// changing, which `NotePadViewModel` observes directly.
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

    private func refreshPublishedState(ownerUserId: String, conversationId: String) {
        let loaded = (try? repository.fetchAll(ownerUserId: ownerUserId, conversationId: conversationId)) ?? []
        itemsByConversation[conversationId] = loaded
    }

    /// Clears the in-memory cache on logout, so a different local account
    /// signing in next doesn't briefly see the previous account's pad
    /// before its own `loadItems` call runs. Does **not** touch the
    /// database — logout must never destroy data (Bug #10); only
    /// `AccountDeletionService` (via `deleteAllOnDisk`) actually deletes rows.
    func clearInMemoryState() {
        itemsByConversation.removeAll()
    }

    /// Used by `AccountDeletionService`. Named distinctly from
    /// `clearInMemoryState()` so the "this permanently deletes from disk"
    /// and "this just resets a view-layer cache" operations can never be
    /// confused for each other at a call site.
    func deleteAllOnDisk(ownerUserId: String) throws {
        try repository.deleteAll(ownerUserId: ownerUserId)
        itemsByConversation.removeAll()
    }
}
