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

    /// FIX (Bug #17): whether the last failure is worth retrying.
    ///
    /// Retrying `awaitingFirstMessage` succeeds as soon as the peer replies; retrying
    /// `invalidSignature` never will. Presenting both identically trained users to
    /// ignore the difference, so the retry affordance is now conditional.
    @Published private(set) var canRetryLastSend = false

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

    /// Held so the retry button can resend exactly what failed.
    private var lastFailedDraft: String?

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
            .sink { [weak self] _ in
                self?.reload()
                // A message from the peer is exactly what unblocks
                // `awaitingFirstMessage`, so refresh the retry affordance.
                self?.reloadPeer()
            }
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
            // FIX (Bug #11): fall back to a shortened id rather than "Unknown".
            peerUsername = peer.username.isEmpty ? String(peer.id.prefix(8)) : peer.username
            peerIsVerified = peer.isVerified
            peerIdentityChanged = peer.hasUnacknowledgedIdentityChange
        } catch {
            errorMessage = "Couldn't load contact: \(error.localizedDescription)"
        }
    }

    func reload() {
        guard let myUserId = authService.currentUserId else { return }
        do {
            let stored = try messageRepository.fetchMessages(
                conversationId: conversation.id,
                ownerUserId: myUserId
            )
            messages = stored.map { message in
                DisplayMessage(
                    id: message.id,
                    isMine: message.senderId == myUserId,
                    // FIX (Bug #18): shared helper, so the bubble and the list summary
                    // can never disagree about how a media message is rendered.
                    text: messagingService.previewText(for: message),
                    contentType: message.contentType,
                    status: message.deliveryStatus,
                    createdAt: message.createdAt
                )
            }
        } catch {
            errorMessage = "Couldn't load messages: \(error.localizedDescription)"
        }
    }

    func dismissReceiveError() {
        messagingService.clearReceiveError()
        receiveError = nil
    }

    func dismissSendError() {
        errorMessage = nil
        canRetryLastSend = false
        lastFailedDraft = nil
    }

    /// FIX (Bug #17): re-attempts the send that failed recoverably.
    func retryLastSend() async {
        guard let draft = lastFailedDraft else { return }
        draftText = draft
        await send()
    }

    func send() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard !peerIdentityChanged else {
            errorMessage = IdentityError.identityChangeUnacknowledged(userId: peerId ?? "").localizedDescription
            canRetryLastSend = false
            return
        }

        draftText = ""
        isSending = true
        defer { isSending = false }

        do {
            try await messagingService.sendText(text, in: conversation)
            errorMessage = nil
            canRetryLastSend = false
            lastFailedDraft = nil
            reload()
        } catch let cryptoError as CryptoError {
            // FIX (Bug #17): a described error and an honest retry affordance,
            // replacing "Couldn't send message: The operation couldn't be completed."
            errorMessage = cryptoError.localizedDescription
            canRetryLastSend = cryptoError.isRecoverable
            lastFailedDraft = cryptoError.isRecoverable ? text : nil
            reload()
        } catch let identityError as IdentityError {
            reloadPeer()
            errorMessage = identityError.localizedDescription
            canRetryLastSend = false
            lastFailedDraft = nil
        } catch {
            errorMessage = error.localizedDescription
            // Network-shaped failures are worth another attempt.
            canRetryLastSend = true
            lastFailedDraft = text
            reload()
        }
    }
}
