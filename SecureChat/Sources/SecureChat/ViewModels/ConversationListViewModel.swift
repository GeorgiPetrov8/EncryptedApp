import Foundation
import Combine

struct ConversationSummary: Identifiable {
    let conversation: Conversation
    let otherUsername: String
    let lastMessagePreview: String
    let lastActivityAt: Date?
    let isVerified: Bool
    let hasIdentityWarning: Bool
    var id: String { conversation.id }
}

@MainActor
final class ConversationListViewModel: ObservableObject {
    @Published private(set) var summaries: [ConversationSummary] = []
    @Published var newConversationUsername = ""
    @Published var errorMessage: String?
    @Published var isStartingConversation = false

    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let userRepository: UserRepository
    private let messagingService: MessagingService
    private let authService: AuthService
    private var cancellables = Set<AnyCancellable>()

    init(
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        userRepository: UserRepository,
        messagingService: MessagingService,
        authService: AuthService
    ) {
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.userRepository = userRepository
        self.messagingService = messagingService
        self.authService = authService

        messagingService.$incomingMessage
            .compactMap { $0 }
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        guard let myUserId = authService.currentUserId else { return }
        do {
            // Scoped to the signed-in account (Bug #10) and ordered by real activity
            // rather than creation date (Bug #15).
            let conversations = try conversationRepository.fetchAllSortedByRecentActivity(ownerUserId: myUserId)
            summaries = try conversations.map { conversation in
                let peerId = conversation.otherParticipant(myUserId: myUserId) ?? ""
                let peer = try userRepository.fetch(id: peerId)
                let last = try messageRepository.latestMessage(
                    conversationId: conversation.id,
                    ownerUserId: myUserId
                )

                // FIX (Bug #18): `previewText`, not `plaintext`.
                //
                // The old call rendered every message as text regardless of type, so a
                // media message printed its raw `MediaKeyPayload` JSON — including the
                // base64 per-file AES key — straight into the chat list, and from
                // there into screenshots and the app-switcher snapshot.
                let preview = last.map { messagingService.previewText(for: $0) } ?? "No messages yet"

                return ConversationSummary(
                    conversation: conversation,
                    // FIX (Bug #11): a real name now, with a shortened id as the last
                    // resort instead of a blanket "Unknown".
                    otherUsername: displayName(for: peer, peerId: peerId),
                    lastMessagePreview: preview,
                    lastActivityAt: last?.createdAt ?? conversation.lastMessageAt,
                    isVerified: peer?.isVerified ?? false,
                    hasIdentityWarning: peer?.hasUnacknowledgedIdentityChange ?? false
                )
            }
        } catch {
            errorMessage = "Couldn't load conversations: \(error.localizedDescription)"
        }
    }

    private func displayName(for peer: User?, peerId: String) -> String {
        if let peer, !peer.username.isEmpty { return peer.username }
        guard !peerId.isEmpty else { return "Unknown contact" }
        return String(peerId.prefix(8))
    }

    func startConversation() async -> Conversation? {
        let username = newConversationUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return nil }
        isStartingConversation = true
        defer { isStartingConversation = false }
        do {
            let conversation = try await messagingService.startConversation(withUsername: username)
            newConversationUsername = ""
            reload()
            return conversation
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
