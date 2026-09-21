import Foundation
import Combine
import PhotosUI

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

    /// Whether the last send failure is worth retrying (Bug #17) — retrying
    /// `awaitingFirstMessage` can succeed once the peer replies; retrying
    /// `invalidSignature` never will.
    @Published private(set) var canRetryLastSend = false

    @Published private(set) var receiveError: String?
    @Published private(set) var peerUsername: String = "Unknown"
    @Published private(set) var peerId: String?
    @Published private(set) var peerIsVerified = false
    @Published private(set) var peerIdentityChanged = false

    /// FIX: the photo picker's selection, bound directly to `ChatView`'s
    /// `PhotosPicker`. Setting it — i.e. the user just picked a photo —
    /// triggers `sendPhoto` immediately. There's no separate "attach, then
    /// press send" step; picking a photo *is* the send action, the same way
    /// tapping the send button is for text.
    @Published var selectedPhotoItem: PhotosPickerItem? {
        didSet {
            // Also fires when this is cleared back to nil (see `sendPhoto`'s
            // own `defer`); the guard makes that a no-op instead of a loop.
            guard let item = selectedPhotoItem else { return }
            Task { await sendPhoto(item) }
        }
    }
    @Published private(set) var isSendingMedia = false

    let conversation: Conversation
    private let messageRepository: MessageRepository
    private let messagingService: MessagingService
    private let authService: AuthService
    private var cancellables = Set<AnyCancellable>()

    /// Held so the retry button can resend exactly what failed.
    private var lastFailedDraft: String?

    /// FIX: the underlying `Message` rows, keyed by id, alongside the
    /// `DisplayMessage` projection already kept in `messages`.
    ///
    /// `MediaMessageView` only ever knows a message's id (it's handed a
    /// `DisplayMessage`, which has no room for raw ciphertext or a
    /// `MediaItem` reference on purpose — see `previewText` never touching
    /// key material, Bug #18). When it asks to decrypt a photo, this is
    /// what lets `loadMediaData(forMessageId:)` find the right row without
    /// a repository round trip keyed on something the view doesn't have.
    private var messagesById: [String: Message] = [:]

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
            messagesById = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
            messages = stored.map { message in
                DisplayMessage(
                    id: message.id,
                    isMine: message.senderId == myUserId,
                    // Shared helper so the bubble and the conversation-list
                    // summary can never disagree about how a media message
                    // is rendered, and so a media message's body — a
                    // key-bearing JSON payload — never reaches a `Text`
                    // view by accident (Bug #18).
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

    /// FIX: the closure `MediaMessageView` calls to decrypt a photo on demand.
    func loadMediaData(forMessageId messageId: String) async -> Data? {
        guard let message = messagesById[messageId] else { return nil }
        do {
            return try await messagingService.mediaData(for: message)
        } catch {
            // A failed decrypt/download here shows the view's own "Couldn't
            // load photo" placeholder; nothing more to surface at this layer.
            return nil
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

    func retryLastSend() async {
        guard let draft = lastFailedDraft else { return }
        draftText = draft
        await send()
    }

    /// FIX: the missing UI-to-backend wire for media.
    ///
    /// `MessagingService.sendMedia` — and everything under it
    /// (`MediaEncryptionService.prepareForSending`, the composite-keyed
    /// `MediaItem` rows from the account-isolation fixes, the real
    /// server's `/media` route) — already worked end-to-end at the
    /// persistence and network layers. Nothing in the view layer ever
    /// called it. This is that call.
    private func sendPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil } // always clear the picker's selection

        guard !peerIdentityChanged else {
            errorMessage = IdentityError.identityChangeUnacknowledged(userId: peerId ?? "").localizedDescription
            return
        }

        isSendingMedia = true
        defer { isSendingMedia = false }

        do {
            let prepared = try await PhotoAttachmentLoader.loadAndPrepare(item)
            try await messagingService.sendMedia(
                rawData: prepared.imageData,
                thumbnail: prepared.thumbnailData,
                mediaType: .image,
                in: conversation
            )
            reload()
        } catch let identityError as IdentityError {
            reloadPeer()
            errorMessage = identityError.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
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
            canRetryLastSend = true
            lastFailedDraft = text
            reload()
        }
    }
}
