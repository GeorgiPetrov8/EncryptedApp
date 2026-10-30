import Foundation
import Combine

struct ConversationSummary: Identifiable {
    let conversation: Conversation
    let peerId: String
    let otherUsername: String
    let lastMessagePreview: String
    let lastActivityAt: Date?
    let isVerified: Bool
    let hasIdentityWarning: Bool
    let relationshipState: RelationshipState

    var id: String { conversation.id }
}

/// The chats list.
///
/// FIX (N+1): every incoming message, receipt, reaction or invitation change
/// reloaded the list, and every reload decrypted the last message of **every**
/// conversation and read each contact separately. Now:
///   - reloads triggered within 150 ms are coalesced into one;
///   - contacts are read in one query;
///   - a conversation's preview is decrypted only when its last message changed
///     (cached by message id + edit time).
///
/// NEW (S34): `delete(_:)` removes a conversation from this phone.
@MainActor
final class ConversationListViewModel: ObservableObject {
    @Published private(set) var summaries: [ConversationSummary] = []
    @Published var errorMessage: String?

    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let userRepository: UserRepository
    private let messagingService: MessagingService
    private let invitationService: InvitationService
    private let authService: AuthService
    private let deletion: ConversationDeletionService?
    private var cancellables = Set<AnyCancellable>()

    private var previewCache: [String: (stamp: String, text: String)] = [:]
    private var pendingReload: Task<Void, Never>?

    init(
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        userRepository: UserRepository,
        messagingService: MessagingService,
        invitationService: InvitationService,
        authService: AuthService,
        deletion: ConversationDeletionService? = nil
    ) {
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.userRepository = userRepository
        self.messagingService = messagingService
        self.invitationService = invitationService
        self.authService = authService
        self.deletion = deletion

        messagingService.$incomingMessage
            .compactMap { $0 }
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &cancellables)

        invitationService.changes
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &cancellables)

        messagingService.conversationChanged
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &cancellables)

        authService.$currentUserId
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.previewCache = [:]
                self?.summaries = []
            }
            .store(in: &cancellables)
    }

    /// Coalesces bursts (a backfill of 50 envelopes = one reload).
    func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func reload() {
        guard let myUserId = authService.currentUserId else { return }
        do {
            let conversations = try conversationRepository.fetchAllSortedByRecentActivity(ownerUserId: myUserId)
                .filter { $0.relationshipState != .invitedByThem }
            let users = Dictionary(
                ((try? userRepository.fetchAll(ownerUserId: myUserId)) ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            var liveIds = Set<String>()
            summaries = try conversations.map { conversation in
                liveIds.insert(conversation.id)
                let peerId = conversation.otherParticipant(myUserId: myUserId) ?? ""
                let peer = users[peerId]
                let last = try messageRepository.latestMessage(conversationId: conversation.id, ownerUserId: myUserId)
                return ConversationSummary(
                    conversation: conversation,
                    peerId: peerId,
                    otherUsername: peer?.shownName ?? (peerId.isEmpty ? "Unknown contact" : String(peerId.prefix(8))),
                    lastMessagePreview: preview(for: conversation, last: last),
                    lastActivityAt: last?.createdAt ?? conversation.lastMessageAt ?? conversation.inviteSentAt,
                    isVerified: peer?.isVerified ?? false,
                    hasIdentityWarning: peer?.hasUnacknowledgedIdentityChange ?? false,
                    relationshipState: conversation.relationshipState
                )
            }
            previewCache = previewCache.filter { liveIds.contains($0.key) }
        } catch {
            errorMessage = "Couldn't load conversations: \(error.localizedDescription)"
        }
    }

    private func preview(for conversation: Conversation, last: Message?) -> String {
        switch conversation.relationshipState {
        case .invitedByMe:
            guard let last else { return "Invitation sent" }
            return "Waiting for acceptance · \(cachedPreview(conversation.id, last))"
        case .declined:
            return "Invitation declined"
        case .accepted, .invitedByThem:
            return last.map { cachedPreview(conversation.id, $0) } ?? "No messages yet"
        }
    }

    private func cachedPreview(_ conversationId: String, _ message: Message) -> String {
        let stamp = "\(message.id)|\(message.editedAt?.timeIntervalSince1970 ?? 0)|\(message.isUndecryptable)"
        if let cached = previewCache[conversationId], cached.stamp == stamp { return cached.text }
        let text = messagingService.previewText(for: message)
        // A locked storage key gives a placeholder; don't cache that.
        if !text.hasPrefix("🔒") {
            previewCache[conversationId] = (stamp, text)
        }
        return text
    }

    // MARK: Deleting (S34)

    func delete(_ summary: ConversationSummary) {
        do {
            try deletion?.delete(conversationId: summary.id)
            previewCache[summary.id] = nil
            summaries.removeAll { $0.id == summary.id }
        } catch {
            errorMessage = "Couldn't delete the chat: \(error.localizedDescription)"
        }
    }
}
