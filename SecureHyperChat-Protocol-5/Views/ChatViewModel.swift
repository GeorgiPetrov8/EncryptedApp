import Foundation
import SwiftUI
import PhotosUI
import Combine
import UniformTypeIdentifiers

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
    let replyTo: ReplyReference?
    let replyAuthorName: String?
    let isEdited: Bool
    let canEdit: Bool
    let copyText: String?
    let gif: GIFAttachment?
    let reactions: [ReactionSummary]
    let myReaction: String?

    var isMediaAttachment: Bool {
        status != .undecryptable && contentType != .text
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [DisplayMessage] = []
    @Published var draftText = ""
    @Published var errorMessage: String?
    @Published var isSending = false
    @Published private(set) var canRetryLastSend = false

    /// NEW (R25): there are older messages than the ones loaded.
    @Published private(set) var hasOlder = false
    @Published private(set) var isLoadingOlder = false

    @Published private(set) var receiveError: String?
    @Published private(set) var peerUsername: String = "Unknown"
    @Published private(set) var peerUnverifiedName: String?
    @Published private(set) var peerId: String?
    @Published private(set) var peerIsVerified = false
    @Published private(set) var peerIdentityChanged = false

    @Published private(set) var relationshipState: RelationshipState = .accepted
    @Published private(set) var isUpdatingInvitation = false
    @Published private(set) var wasRemoved = false

    @Published private(set) var replyingTo: DisplayMessage?
    @Published private(set) var editing: DisplayMessage?
    @Published private(set) var focusRequest = 0

    @Published var sharedFile: ExportedFile?
    @Published var playingVideo: ExportedFile?

    @Published var selectedPhotoItem: PhotosPickerItem? {
        didSet {
            guard let item = selectedPhotoItem else { return }
            Task { await sendPickedItem(item) }
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

    private var lastFailedMessageId: String?
    private var messagesById: [String: Message] = [:]
    private var isVisible = false

    // MARK: Paging (R25)

    /// The chat used to load and decrypt the **whole** history on every incoming
    /// message, receipt and reaction. Now it loads the newest `pageLimit`
    /// messages and grows the window when the user scrolls to the top.
    static let pageSize = 100
    private var pageLimit = ChatViewModel.pageSize

    /// Decrypted content per message, so a reload only decrypts what's new or
    /// edited. Keyed by message id; `stamp` invalidates it on edit.
    private struct Decoded {
        let stamp: String
        let text: TextPayload?
        let media: MediaDisplayMetadata?
        let preview: String
    }
    private var decodedCache: [String: Decoded] = [:]

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

    func declineInvitation(block: Bool = false) async {
        isUpdatingInvitation = true
        defer { isUpdatingInvitation = false }
        await invitationService.decline(conversation, block: block)
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
            decodedCache[message.id] = nil
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

    // MARK: Reactions

    func react(to message: DisplayMessage, emoji: String?) {
        guard canCompose, message.status != .undecryptable else { return }
        Task {
            do {
                try await messagingService.sendReaction(messageId: message.id, emoji: emoji, in: conversation)
            } catch {
                errorMessage = "Couldn't send the reaction: \(error.localizedDescription)"
            }
            reload()
        }
    }

    // MARK: Saving / sharing / playing media

    func shareMedia(messageId: String) async {
        guard let url = await exportDecryptedCopy(messageId: messageId) else { return }
        sharedFile = ExportedFile(url: url)
    }

    func playVideo(messageId: String) async {
        guard let url = await exportDecryptedCopy(messageId: messageId) else { return }
        playingVideo = ExportedFile(url: url)
    }

    func finishedWith(_ file: ExportedFile) {
        MediaExporter.remove(file.url)
        if sharedFile?.id == file.id { sharedFile = nil }
        if playingVideo?.id == file.id { playingVideo = nil }
    }

    private func exportDecryptedCopy(messageId: String) async -> URL? {
        guard let message = messagesById[messageId],
              let data = await loadMediaData(forMessageId: messageId) else {
            if errorMessage == nil { errorMessage = "Couldn't open that attachment." }
            return nil
        }
        let expected = decoded(message).media?.mediaType
        var fileExtension = "bin"
        if case .success(let accepted) = AttachmentPolicy.checkReceived(data, expected: expected) {
            fileExtension = accepted.displayExtension
        }
        let prefix: String
        switch expected {
        case .image: prefix = "SecureHyperChat-Photo"
        case .video: prefix = "SecureHyperChat-Video"
        case .audio: prefix = "SecureHyperChat-Voice"
        case .document, .none: prefix = "SecureHyperChat-File"
        }
        do {
            return try MediaExporter.write(data, fileExtension: fileExtension, prefix: prefix)
        } catch {
            errorMessage = "Couldn't prepare the file: \(error.localizedDescription)"
            return nil
        }
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
            peerUnverifiedName = peer.unverifiedDisplayName
            peerIsVerified = peer.isVerified
            peerIdentityChanged = peer.hasUnacknowledgedIdentityChange
        } catch {
            errorMessage = "Couldn't load contact: \(error.localizedDescription)"
        }
    }

    /// Called when the top of the list appears. Loads `pageSize` more.
    func loadOlder() {
        guard hasOlder, !isLoadingOlder else { return }
        isLoadingOlder = true
        pageLimit += Self.pageSize
        reload()
        isLoadingOlder = false
    }

    private func decoded(_ message: Message) -> Decoded {
        let stamp = "\(message.editedAt?.timeIntervalSince1970 ?? 0)|\(message.isUndecryptable)|\(message.encryptedContent.count)"
        if let cached = decodedCache[message.id], cached.stamp == stamp { return cached }
        let text = messagingService.textContent(for: message)
        let media = messagingService.mediaDisplayMetadata(for: message)
        let preview: String
        if message.contentType == .text {
            preview = text?.text ?? messagingService.previewText(for: message)
        } else if message.isUndecryptable {
            preview = messagingService.previewText(for: message)
        } else {
            switch message.contentType {
            case .image: preview = "📷 Photo"
            case .video: preview = "🎥 Video"
            default: preview = media?.mediaType == .audio ? "🎤 Voice message" : "📎 File"
            }
        }
        let value = Decoded(stamp: stamp, text: text, media: media, preview: preview)
        decodedCache[message.id] = value
        return value
    }

    func reload() {
        guard let myUserId = authService.currentUserId else { return }
        do {
            let stored = try messageRepository.fetchRecentMessages(
                conversationId: conversation.id, ownerUserId: myUserId, limit: pageLimit
            )
            let total = try messageRepository.countMessages(conversationId: conversation.id, ownerUserId: myUserId)
            hasOlder = total > stored.count

            messagesById = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
            let liveIds = Set(messagesById.keys)
            decodedCache = decodedCache.filter { liveIds.contains($0.key) }

            let reactionsByMessage = Dictionary(
                grouping: ((try? messageRepository.fetchReactions(messageIds: Array(liveIds), ownerUserId: myUserId)) ?? [])
                    .filter { !$0.emoji.isEmpty },
                by: \.messageId
            )

            messages = stored.map { message in
                let content = decoded(message)
                let gif = content.text?.gif
                let reactions = reactionsByMessage[message.id] ?? []
                let quote = verifiedQuote(content.text?.replyTo, me: myUserId)
                return DisplayMessage(
                    id: message.id,
                    senderId: message.senderId,
                    isMine: message.senderId == myUserId,
                    text: content.preview,
                    contentType: message.contentType,
                    mediaType: content.media?.mediaType,
                    voiceDuration: content.media?.duration,
                    voiceWaveform: content.media?.waveform,
                    status: message.deliveryStatus,
                    createdAt: message.createdAt,
                    deliveredAt: message.deliveredAt,
                    readAt: message.readAt,
                    replyTo: quote?.reference,
                    replyAuthorName: quote?.author,
                    isEdited: message.editedAt != nil,
                    canEdit: messagingService.canEdit(message),
                    copyText: gif == nil ? content.text?.text : nil,
                    gif: gif,
                    reactions: Self.summaries(reactions, me: myUserId),
                    myReaction: reactions.first { $0.reactorId == myUserId }?.emoji
                )
            }

            lastFailedMessageId = stored
                .filter { $0.senderId == myUserId && $0.deliveryStatus == .failed }
                .max { $0.createdAt < $1.createdAt }?
                .id
            markVisibleMessagesRead()
        } catch {
            errorMessage = "Couldn't load messages: \(error.localizedDescription)"
        }
    }

    /// The quote is rebuilt from our own copy of the quoted message (S32). With
    /// paging the original may be outside the loaded window, so it is looked up
    /// directly.
    private func verifiedQuote(_ reply: ReplyReference?, me: String) -> (reference: ReplyReference, author: String)? {
        guard let reply else { return nil }
        let original = messagesById[reply.messageId]
            ?? (try? messageRepository.fetch(messageId: reply.messageId, ownerUserId: me))
        if let original, original.conversationId == conversation.id {
            let reference = ReplyReference(
                messageId: original.id,
                senderId: original.senderId,
                preview: SafeText.preview(decoded(original).preview) ?? "",
                contentType: original.contentType
            )
            return (reference, original.senderId == me ? "You" : peerUsername)
        }
        let reference = ReplyReference(
            messageId: reply.messageId,
            senderId: reply.senderId,
            preview: SafeText.preview(reply.preview) ?? "",
            contentType: reply.contentType
        )
        return (reference, "Quoted message (not on this device)")
    }

    private static func summaries(_ reactions: [MessageReaction], me: String) -> [ReactionSummary] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var mine: String?
        for reaction in reactions.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            if counts[reaction.emoji] == nil { order.append(reaction.emoji) }
            counts[reaction.emoji, default: 0] += 1
            if reaction.reactorId == me { mine = reaction.emoji }
        }
        return order.map { ReactionSummary(emoji: $0, count: counts[$0] ?? 0, includesMe: $0 == mine) }
    }

    func loadMediaData(forMessageId messageId: String) async -> Data? {
        guard let message = messagesById[messageId] else { return nil }
        do {
            return try await messagingService.mediaData(for: message)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't open that attachment."
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
    }

    func retryLastSend() async {
        guard let messageId = lastFailedMessageId else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await messagingService.retry(messageId: messageId, in: conversation)
            errorMessage = nil
            canRetryLastSend = false
        } catch {
            errorMessage = error.localizedDescription
            canRetryLastSend = true
        }
        reload()
    }

    // MARK: Media

    private func sendPickedItem(_ item: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil }
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }

        await sendMediaGuarded {
            if isVideo {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw PhotoAttachmentLoader.LoadError.noData
                }
                defer { MediaExporter.remove(movie.url) }
                let data = try await VideoCompressor.prepare(movie.url)
                try await self.messagingService.sendMedia(rawData: data, thumbnail: nil, mediaType: .video, in: self.conversation)
            } else {
                let prepared = try await PhotoAttachmentLoader.loadAndPrepare(item)
                try await self.messagingService.sendMedia(
                    rawData: prepared.imageData, thumbnail: nil, mediaType: .image, in: self.conversation
                )
            }
        }
    }

    func sendCapturedMedia(_ capture: CameraPicker.Capture) async {
        await sendMediaGuarded {
            switch capture {
            case .photo(let data):
                try await self.messagingService.sendMedia(rawData: data, thumbnail: nil, mediaType: .image, in: self.conversation)
            case .video(let url):
                let data = try await VideoCompressor.prepare(url)
                try await self.messagingService.sendMedia(rawData: data, thumbnail: nil, mediaType: .video, in: self.conversation)
            }
        }
    }

    func sendDocument(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: url)
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        guard size <= AttachmentPolicy.maxBytes else {
            errorMessage = "That file is too large to send (the limit is \(AttachmentPolicy.maxBytes / 1_048_576) MB)."
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            errorMessage = "Couldn't read that file: \(error.localizedDescription)"
            return
        }

        if case .failure(let rejection) = AttachmentPolicy.inspect(data: data, declaredExtension: url.pathExtension) {
            errorMessage = rejection.localizedDescription
            return
        }

        await sendMediaGuarded {
            try await self.messagingService.sendMedia(rawData: data, thumbnail: nil, mediaType: .document, in: self.conversation)
        }
    }

    func sendGIF(_ gif: GIFAttachment) async {
        guard canCompose else {
            errorMessage = composeDisabledReason
            return
        }
        let reply = replyingTo.map(replyReference)
        replyingTo = nil
        isSending = true
        defer { isSending = false }
        do {
            try await messagingService.sendGIF(gif, replyTo: reply, in: conversation)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
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
            errorMessage = nil
            reload()
        } catch let identityError as IdentityError {
            reloadPeer()
            errorMessage = identityError.localizedDescription
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            reload()
            canRetryLastSend = lastFailedMessageId != nil
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
            reload()
        } catch let identityError as IdentityError {
            reloadPeer()
            errorMessage = identityError.localizedDescription
            canRetryLastSend = false
        } catch let invitationError as InvitationError {
            draftText = text
            errorMessage = invitationError.localizedDescription
            canRetryLastSend = false
        } catch {
            errorMessage = error.localizedDescription
            reload()
            canRetryLastSend = lastFailedMessageId != nil
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
