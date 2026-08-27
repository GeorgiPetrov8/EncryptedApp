import Foundation
import Combine

struct DisplayMessage: Identifiable {
    let id: String
    let isMine: Bool
    let text: String
    let contentType: MessageContentType
    let status: DeliveryStatus
    let createdAt: Date
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [DisplayMessage] = []
    @Published var draftText = ""
    @Published var errorMessage: String?
    @Published var isSending = false

    /// FIX (Bug #9): receive-side failures, mirrored from `MessagingService`.
    @Published private(set) var receiveError: String?

    @Published private(set) var peerUsername: String = "Unknown"
    @Published private(set) var peerId: String?
    @Published private(set) var peerIsVerified = false
    @Published private(set) var peerIdentityChanged = false

    let conversation: Conversation
    private let messageRepository: MessageRepository
    private let messagingService: MessagingService
    private let authService: AuthService
    private var cancellables = Set<AnyCancellable>()

    init(
        conversation: Conversation,
        messageRepository: MessageRepository,
        messagingService: MessagingService,
        authService: AuthService
    ) {
        self.conversation = conversation
        self.messageRepository = messageRepository
        self.messagingService = messagingService
        self.authService = authService

        messagingService.$incomingMessage
            .compactMap { $0 }
            .filter { $0.conversationId == conversation.id }
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        messagingService.$identityAlert
            .sink { [weak self] _ in self?.reloadPeer() }
            .store(in: &cancellables)

        messagingService.$lastReceiveError
            .sink { [weak self] value in self?.receiveError = value }
            .store(in: &cancellables)

        reloadPeer()
        reload()
    }

    func reloadPeer() {
        do {
            guard let peer = try messagingService.peer(for: conversation) else { return }
            peerId = peer.id
            peerUsername = peer.username
            peerIsVerified = peer.isVerified
            peerIdentityChanged = peer.hasUnacknowledgedIdentityChange
        } catch {
            errorMessage = "Couldn't load contact: \(error.localizedDescription)"
        }
    }

    func reload() {
        guard let myUserId = authService.currentUserId else { return }
        do {
            // FIX (Bug #10): scoped to the signed-in account.
            let stored = try messageRepository.fetchMessages(
                conversationId: conversation.id,
                ownerUserId: myUserId
            )
            messages = stored.map { message in
                DisplayMessage(
                    id: message.id,
                    isMine: message.senderId == myUserId,
                    text: displayText(for: message),
                    contentType: message.contentType,
                    status: message.deliveryStatus,
                    createdAt: message.createdAt
                )
            }
        } catch {
            errorMessage = "Couldn't load messages: \(error.localizedDescription)"
        }
    }

    private func displayText(for message: Message) -> String {
        // Undecryptable placeholders carry no content, so the content-type branch
        // must not run for them.
        if message.isUndecryptable {
            return messagingService.displayText(for: message)
        }
        return message.contentType == .text
            ? messagingService.displayText(for: message)
            : "[\(message.contentType.rawValue) message]"
    }

    func dismissReceiveError() {
        messagingService.clearReceiveError()
        receiveError = nil
    }

    func send() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard !peerIdentityChanged else {
            errorMessage = IdentityError.identityChangeUnacknowledged(userId: peerId ?? "").localizedDescription
            return
        }

        draftText = ""
        isSending = true
        defer { isSending = false }
        do {
            try await messagingService.sendText(text, in: conversation)
            reload()
        } catch let identityError as IdentityError {
            reloadPeer()
            errorMessage = identityError.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
