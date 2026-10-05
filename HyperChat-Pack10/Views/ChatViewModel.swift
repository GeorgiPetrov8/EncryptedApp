import Foundation
import SwiftUI
import PhotosUI
import Combine

struct DisplayMessage: Identifiable {
    let id: String
    let senderId: String
    let isMine: Bool
    let text: String
    let contentType: MessageContentType
    let mediaType: MediaType?
    let voiceDuration: TimeInterval?
    let voiceWaveform: [Float]?
    let status: DeliveryStatus
    let createdAt: Date
    let deliveredAt: Date?
    let readAt: Date?
    /// The message this one replies to, if any.
    let replyTo: ReplyReference?
    /// "You" or the contact's name, for the quote header.
    let replyAuthorName: String?
    let isEdited: Bool
    let canEdit: Bool
    /// Text to copy; nil for media.
    let copyText: String?
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [DisplayMessage] = []
    @Published var draftText = ""
    @Published var errorMessage: String?
    @Published var isSending = false
    @Published private(set) var canRetryLastSend = false

    @Published private(set) var receiveError: String?
    @Published private(set) var peerUsername: String = "Unknown"
    @Published private(set) var peerId: String?
    @Published private(set) var peerIsVerified = false
    @Published private(set) var peerIdentityChanged = false

    @Published private(set) var relationshipState: RelationshipState = .accepted
    @Published private(set) var isUpdatingInvitation = false
    @Published private(set) var wasRemoved = false

    /// The message being replied to (shown above the composer).
    @Published private(set) var replyingTo: DisplayMessage?
    /// The message being edited (its text is loaded into the composer).
    @Published private(set) var editing: DisplayMessage?
    /// Bumped to move keyboard focus into the composer.
    @Published private(set) var focusRequest = 0

    @Published var selectedPhotoItem: PhotosPickerItem? {
        didSet {
            guard let item = selectedPhotoItem else { return }
            Task { await sendPhoto(item) }
        }
    }
    @Published private(set) var isSendingMedia = false

    private(set) var conversation: Conversation
    private let messageRepository: MessageRepository
    private let conversationRepository: ConversationRepository
    private let messagingService: MessagingService
    private let authService: AuthService
    private let receiptService: ReceiptService
    private let invitationService: InvitationService
    private var cancellables = Set<AnyCancellable>()

    private var lastFailedDraft: String?
    private var messagesById: [String: Message] = [:]
    private var isVisible = false

    init(
        conversation: Conversation,
        messageRepository: MessageRepository,
        conversationRepository: ConversationRepository,
        messagingService: MessagingService,
        authService: AuthService,
        receiptService: ReceiptService,
        invitationService: InvitationService
    ) {
        self.conversation = conversation
        self.messageRepository = messageRepository
        self.conversationRepository = conversationRepository
        self.messagingService = messagingService
        self.authService = authService
        self.receiptService = receiptService
        self.invitationService = invitationService
        self.relationshipState = conversation.relationshipState

        let conversationId = conversation.id

        messagingService.$incomingMessage
            .compactMap { $0 }
            .filter { $0.conversationId == conversationId }
            .sink { [weak self] _ in
                self?.reloadConversation()
                self?.reload()
                self?.reloadPeer()
            }
            .store(in: &cancellables)

        messagingService.conversationChanged
            .filter { $0 == conversationId }
            .sink { [weak self] _ in
                self?.reloadConversation()
                self?.reload()
            }
            .store(in: &cancellables)

        invitationService.changes
            .filter { $0 == conversationId }
            .sink { [weak self] _ in
                self?.reloadConversation()
                self?.reload()
            }
            .store(in: &cancellables)

        receiptService.updates
            .filter { $0 == conversationId }
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        messagingService.$identityAlert
            .sink { [weak self] _ in self?.reloadPeer() }
            .store(in: &cancellables)

        messagingService.$lastReceiveError
            .sink { [weak self] value in self?.receiveError = value }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.markVisibleMessagesRead() }
            .store(in: &cancellables)

        reloadConversation()
        reloadPeer()
        reload()
    }

    // MARK: Invitation state

    var canCompose: Bool {
        !peerIdentityChanged && (relationshipState == .accepted || relationshipState == .invitedByMe)
    }

    var canCall: Bool {
        !peerIdentityChanged && relationshipState == .accepted
    }

    var composeDisabledReason: String? {
        if peerIdentityChanged { return "Verification required" }
        switch relationshipState {
        case .accepted, .invitedByMe: return nil
        case .invitedByThem: return "Accept to reply"
        case .declined: return "Invitation declined"
        }
    }

    func reloadConversation() {
        guard let myUserId = authService.currentUserId else { return }
        if let fresh = try? conversationRepository.fetch(id: conversation.id, ownerUserId: myUserId) {
            conversation = fresh
            relationshipState = fresh.relationshipState
        } else {
            wasRemoved = true
        }
    }

    func acceptInvitation() async {
        isUpdatingInvitation = true
        defer { isUpdatingInvitation = false }
        conversation = await invitationService.accept(conversation)
        relationshipState = conversation.relationshipState
        reload()
    }

    func declineInvitation() async {
        isUpdatingInvitation = true
        defer { isUpdatingInvitation = false }
        await invitationService.decline(conversation)
        wasRemoved = true
    }

    func resendInvitation() async {
        isUpdatingInvitation = true
        defer { isUpdatingInvitation = false }
        do {
            try await invitationService.resend(conversation)
            errorMessage = nil
            reloadConversation()
        } catch {
            errorMessage = "Couldn't send the invitation: \(error.localizedDescription)"
        }
    }

    // MARK: Reply / edit / delete

    func startReply(to message: DisplayMessage) {
        guard canCompose, message.status != .undecryptable else { return }
        editing = nil
        replyingTo = message
        focusRequest += 1
    }

    func startEdit(_ message: DisplayMessage) {
        guard message.canEdit, let text = message.copyText else { return }
        replyingTo = nil
        editing = message
        draftText = text
        focusRequest += 1
    }

    func cancelComposerContext() {
        if editing != nil { draftText = "" }
        editing = nil
        replyingTo = nil
    }

    func deleteForMe(_ message: DisplayMessage) {
        do {
            try messagingService.deleteMessageLocally(messageId: message.id, conversationId: conversation.id)
            if replyingTo?.id == message.id { replyingTo = nil }
            if editing?.id == message.id { cancelComposerContext() }
        } catch {
            errorMessage = "Couldn't delete the message: \(error.localizedDescription)"
        }
    }

    private func replyReference(for message: DisplayMessage) -> ReplyReference {
        ReplyReference(
            messageId: message.id,
            senderId: message.senderId,
            preview: String(message.text.prefix(ReplyReference.maxPreviewLength)),
            contentType: message.contentType
        )
    }

    // MARK: Visibility (read receipts)

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible { markVisibleMessagesRead() }
    }

    private func markVisibleMessagesRead() {
        guard isVisible,
              relationshipState == .accepted,
              UIApplication.shared.applicationState == .active,
              let myUserId = authService.currentUserId else { return }

        let unread = messagesById.values
            .filter { $0.senderId != myUserId && $0.readAt == nil && !$0.isUndecryptable }
            .map(\.id)
        guard !unread.isEmpty else { return }

        receiptService.markRead(messageIds: unread, in: conversation)
        for id in unread { messagesById[id]?.readAt = Date() }
    }

    // MARK: Loading

    func reloadPeer() {
        do {
            guard let peer = try messagingService.peer(for: conversation) else { return }
            peerId = peer.id
            peerUsername = peer.shownName
            peerIsVerified = peer.isVerified
            peerIdentityChanged = peer.hasUnacknowledgedIdentityChange
        } catch {
            errorMessage = "Couldn't load contact: \(error.localizedDescription)"
        }
    }

    func reload() {
        guard let myUserId = authService.currentUserId else { return }
        do {
            let stored = try messageRepository.fetchMessages(conversationId: conversation.id, ownerUserId: myUserId)
            messagesById = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
            messages = stored.map { message in
                let media = messagingService.mediaDisplayMetadata(for: message)
                let textPayload = messagingService.textContent(for: message)
                let reply = textPayload?.replyTo
                return DisplayMessage(
                    id: message.id,
                    senderId: message.senderId,
                    isMine: message.senderId == myUserId,
                    text: textPayload?.text ?? messagingService.previewText(for: message),
                    contentType: message.contentType,
                    mediaType: media?.mediaType,
                    voiceDuration: media?.duration,
                    voiceWaveform: media?.waveform,
                    status: message.deliveryStatus,
                    createdAt: message.createdAt,
                    deliveredAt: message.deliveredAt,
                    readAt: message.readAt,
                    replyTo: reply,
                    replyAuthorName: reply.map { $0.senderId == myUserId ? "You" : peerUsername },
                    isEdited: message.editedAt != nil,
                    canEdit: messagingService.canEdit(message),
                    copyText: textPayload?.text
                )
            }
            markVisibleMessagesRead()
        } catch {
            errorMessage = "Couldn't load messages: \(error.localizedDescription)"
        }
    }

    func loadMediaData(forMessageId messageId: String) async -> Data? {
        guard let message = messagesById[messageId] else { return nil }
        return try? await messagingService.mediaData(for: message)
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

    // MARK: Media

    private func sendPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil }
        await sendMediaGuarded {
            let prepared = try await PhotoAttachmentLoader.loadAndPrepare(item)
            try await self.messagingService.sendMedia(
                rawData: prepared.imageData,
                thumbnail: prepared.thumbnailData,
                mediaType: .image,
                in: self.conversation
            )
        }
    }

    func sendCapturedMedia(_ capture: CameraPicker.Capture) async {
        await sendMediaGuarded {
            switch capture {
            case .photo(let data):
                try await self.messagingService.sendMedia(rawData: data, thumbnail: nil, mediaType: .image, in: self.conversation)
            case .video(let url):
                let data = try Data(contentsOf: url)
                try await self.messagingService.sendMedia(rawData: data, thumbnail: nil, mediaType: .video, in: self.conversation)
            }
        }
    }

    func sendDocument(from url: URL) async {
        await sendMediaGuarded {
            let data = try Data(contentsOf: url)
            try await self.messagingService.sendMedia(rawData: data, thumbnail: nil, mediaType: .document, in: self.conversation)
        }
    }

    func sendGIF(_ data: Data) async {
        await sendMediaGuarded {
            try await self.messagingService.sendMedia(rawData: data, thumbnail: nil, mediaType: .image, in: self.conversation)
        }
    }

    func sendVoiceMessage(_ voiceMessage: RecordedVoiceMessage) async {
        await sendMediaGuarded {
            try await self.messagingService.sendMedia(
                rawData: voiceMessage.data,
                thumbnail: nil,
                mediaType: .audio,
                duration: voiceMessage.duration,
                waveform: voiceMessage.normalisedWaveform(),
                in: self.conversation
            )
        }
    }

    private func sendMediaGuarded(_ operation: () async throws -> Void) async {
        guard !peerIdentityChanged else {
            errorMessage = IdentityError.identityChangeUnacknowledged(userId: peerId ?? "").localizedDescription
            return
        }
        isSendingMedia = true
        defer { isSendingMedia = false }
        do {
            try await operation()
            reload()
        } catch let identityError as IdentityError {
            reloadPeer()
            errorMessage = identityError.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
            reload()
        }
    }

    // MARK: Text

    func send() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let editing {
            await saveEdit(of: editing, text: text)
            return
        }

        guard !peerIdentityChanged else {
            errorMessage = IdentityError.identityChangeUnacknowledged(userId: peerId ?? "").localizedDescription
            canRetryLastSend = false
            return
        }

        let reply = replyingTo.map(replyReference)
        draftText = ""
        replyingTo = nil
        isSending = true
        defer { isSending = false }

        do {
            try await messagingService.sendText(text, replyTo: reply, in: conversation)
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
        } catch let invitationError as InvitationError {
            draftText = text
            errorMessage = invitationError.localizedDescription
            canRetryLastSend = false
        } catch {
            errorMessage = error.localizedDescription
            canRetryLastSend = true
            lastFailedDraft = text
            reload()
        }
    }

    private func saveEdit(of message: DisplayMessage, text: String) async {
        isSending = true
        defer { isSending = false }
        do {
            try await messagingService.editMessage(messageId: message.id, newText: text, in: conversation)
            editing = nil
            draftText = ""
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
