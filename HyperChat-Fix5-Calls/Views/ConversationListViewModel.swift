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
    private var cancellables = Set<AnyCancellable>()

    init(
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        userRepository: UserRepository,
        messagingService: MessagingService,
        invitationService: InvitationService,
        authService: AuthService
    ) {
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.userRepository = userRepository
        self.messagingService = messagingService
        self.invitationService = invitationService
        self.authService = authService

        messagingService.$incomingMessage
            .compactMap { $0 }
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        // FIX (invitations): invitation changes (sent, accepted, declined)
        // aren't incoming messages, so the list needs its own trigger.
        invitationService.changes
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        messagingService.conversationChanged
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        guard let myUserId = authService.currentUserId else { return }
        do {
            let conversations = try conversationRepository.fetchAllSortedByRecentActivity(ownerUserId: myUserId)
                // Requests you haven't answered live in Invitations, not here.
                .filter { $0.relationshipState != .invitedByThem }

            summaries = try conversations.map { conversation in
                let peerId = conversation.otherParticipant(myUserId: myUserId) ?? ""
                let peer = peerId.isEmpty ? nil : try userRepository.fetch(ownerUserId: myUserId, id: peerId)
                let last = try messageRepository.latestMessage(
                    conversationId: conversation.id,
                    ownerUserId: myUserId
                )

                return ConversationSummary(
                    conversation: conversation,
                    peerId: peerId,
                    otherUsername: displayName(for: peer, peerId: peerId),
                    lastMessagePreview: preview(for: conversation, last: last),
                    lastActivityAt: last?.createdAt ?? conversation.lastMessageAt ?? conversation.inviteSentAt,
                    isVerified: peer?.isVerified ?? false,
                    hasIdentityWarning: peer?.hasUnacknowledgedIdentityChange ?? false,
                    relationshipState: conversation.relationshipState
                )
            }
        } catch {
            errorMessage = "Couldn't load conversations: \(error.localizedDescription)"
        }
    }

    private func preview(for conversation: Conversation, last: Message?) -> String {
        switch conversation.relationshipState {
        case .invitedByMe:
            guard let last else { return "Invitation sent" }
            return "Waiting for acceptance · \(messagingService.previewText(for: last))"
        case .declined:
            return "Invitation declined"
        case .accepted, .invitedByThem:
            // `previewText`, not `plaintext` — a media message's body is a
            // key-bearing JSON payload and must never be rendered (Bug #18).
            return last.map { messagingService.previewText(for: $0) } ?? "No messages yet"
        }
    }

    private func displayName(for peer: User?, peerId: String) -> String {
        if let peer { return peer.shownName }
        guard !peerId.isEmpty else { return "Unknown contact" }
        return String(peerId.prefix(8))
    }
}
