import Foundation
import Combine

struct ConversationSummary: Identifiable {
    let conversation: Conversation
    let otherUsername: String
    let lastMessagePreview: String
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
            // FIX (Bug #10): scoped to the signed-in account. Without this filter a
            // second account on the same device listed the first account's
            // conversations — and couldn't decrypt any of them.
            let conversations = try conversationRepository.fetchAllSortedByRecentActivity(ownerUserId: myUserId)
            summaries = try conversations.map { conversation in
                let peerId = conversation.otherParticipant(myUserId: myUserId) ?? ""
                let peer = try userRepository.fetch(id: peerId)
                let last = try messageRepository.latestMessage(
                    conversationId: conversation.id,
                    ownerUserId: myUserId
                )
                let preview = last.map { messagingService.displayText(for: $0) } ?? "No messages yet"
                return ConversationSummary(
                    conversation: conversation,
                    otherUsername: peer?.username ?? String(peerId.prefix(8)),
                    lastMessagePreview: preview
                )
            }
        } catch {
            errorMessage = "Couldn't load conversations: \(error.localizedDescription)"
        }
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
