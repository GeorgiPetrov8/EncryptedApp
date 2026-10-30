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

/// Where the chat should scroll to. A new `token` = a new request.
struct ChatScrollRequest: Equatable {
    enum Target: Equatable { case bottom, message(String) }
    let target: Target
    let token: Int
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [DisplayMessage] = []
    @Published var draftText = ""
    @Published var errorMessage: String?
    @Published var isSending = false
    @Published private(set) var canRetryLastSend = false

    @Published private(set) var hasOlder = false
    @Published private(set) var isLoadingOlder = false

    /// NEW (#4): the first message that was unread when the chat was opened (or
    /// the app came back). The view draws the "Unread messages" line above it.
    @Published private(set) var unreadAnchorId: String?
    @Published private(set) var unreadCount = 0
    @Published private(set) var scrollRequest: ChatScrollRequest?

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
    private let draftStore: DraftStore
    private var cancellables = Set<AnyCancellable>()

    private var lastFailedMessageId: String?
    private var messagesById: [String: Message] = [:]
    private var isVisible = false
    private var scrollToken = 0
    private var hasPositioned = false
    /// Messages fetched right after returning to the app still count as "new".
    private var lastActivatedAt = Date()

    static let pageSize = 100
    private static let maxAutoPage = 1_000
    private var pageLimit = ChatViewModel.pageSize

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
        invitationService: InvitationService,
        draftStore: DraftStore = DraftStore()
    ) {
        self.conversation = conversation
        self.messageRepository = messageRepository
        self.conversationRepository = conversationRepository
        self.messagingService = messagingService
        self.authService = authService
        self.receiptService = receiptService
        self.invitationService = invitationService
        self.draftStore = draftStore
        self.relationshipState = conversation.relationshipState

        let conversationId = conversation.id

        if let me = authService.currentUserId {
            draftText = draftStore.load(conversationId: conversationId, ownerUserId: me)
        }

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

        // #4: coming back to the app shows what arrived meanwhile.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.lastActivatedAt = Date()
                self?.captureUnreadAnchor(scroll: true)
                self?.markVisibleMessagesRead()
            }
            .store(in: &cancellables)

        // #9: drafts are saved half a second after typing stops.
        $draftText
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] text in self?.persistDraft(text) }
            .store(in: &cancellables)

        reloadConversation()
        reloadPeer()
        reload()
    }

    // MARK: Drafts (#9)

    private func persistDraft(_ text: String) {
        guard editing == nil, let me = authService.currentUserId else { return }
        draftStore.save(text, conversationId: conversation.id, ownerUserId: me)
    }

    func saveDraftNow() {
        persistDraft(draftText)
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
        saveDraftNow()
        replyingTo = nil
        editing = message
        draftText = text
        focusRequest += 1
    }

    func cancelComposerContext() {
        if editing != nil {
            editing = nil
            if let me = authService.currentUserId {
                draftText = draftStore.load(conversationId: conversation.id, ownerUserId: me)
            } else {
                draftText = ""
            }
        }
        replyingTo = nil
    }

    func deleteForMe(_ message: DisplayMessage) {
        do {
            try messagingService.deleteMessageLocally(messageId: message.id, conversationId: conversation.id)
            decodedCache[message.id] = nil
            if replyingTo?.id == message.id { replyingTo = nil }
            if editing?.id == message.id { cancelComposerContext() }
            if unreadAnchorId == message.id { unreadAnchorId = nil }
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

    // MARK: Visibility, unread line, read receipts

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible {
            lastActivatedAt = Date()
            captureUnreadAnchor(scroll: true)
            markVisibleMessagesRead()
        } else {
            saveDraftNow()
            unreadAnchorId = nil
            unreadCount = 0
            hasPositioned = false
        }
    }

    /// Remembers the oldest unread incoming message (#4) and asks the view to
    /// scroll there. With nothing unread, the first positioning goes to the bottom.
    private func captureUnreadAnchor(scroll: Bool) {
        guard let me = authService.currentUserId else { return }
        let unread = messagesById.values
            .filter { $0.senderId != me && $0.readAt == nil && !$0.isUndecryptable }
            .sorted { $0.createdAt < $1.createdAt }

        if let first = unread.first {
            unreadAnchorId = first.id
            unreadCount = unread.count
            if scroll { requestScroll(.message(first.id)) }
            hasPositioned = true
        } else if !hasPositioned {
            if scroll { requestScroll(.bottom) }
            hasPositioned = true
        }
    }

    private func requestScroll(_ target: ChatScrollRequest.Target) {
        scrollToken += 1
        scrollRequest = ChatScrollRequest(target: target, token: scrollToken)
    }

    func scrollToBottom() {
        requestScroll(.bottom)
    }

    private func markVisibleMessagesRead() {
        guard isVisible,
              relationshipState == .accepted,
              UIApplication.shared.applicationState == .active,
              let myUserId = authService.currentUserId else { return }

        let unread = messagesById.values
            .filter { $0.senderId != myUserId && $0.readAt == nil && !$0.isUndecryptable }
        guard !unread.isEmpty else { return }

        // Messages fetched right after returning to the app (backfill) get the
        // unread line too, instead of being silently marked read.
        if unreadAnchorId == nil, Date().timeIntervalSince(lastActivatedAt) < 10 {
            captureUnreadAnchor(scroll: true)
        }

        let ids = unread.map(\.id)
        receiptService.markRead(messageIds: ids, in: conversation)
        for id in ids { messagesById[id]?.readAt = Date() }
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

    /// Loads the window; grows it (up to 1 000) until every unread message is in it,
    /// so the unread line can always be shown.
    private func fetchWindow(me: String) throws -> (messages: [Message], total: Int) {
        let total = try messageRepository.countMessages(conversationId: conversation.id, ownerUserId: me)
        var stored = try messageRepository.fetchRecentMessages(conversationId: conversation.id, ownerUserId: me, limit: pageLimit)
        while stored.count < total, pageLimit < Self.maxAutoPage,
              let oldest = stored.first, oldest.senderId != me, oldest.readAt == nil {
            pageLimit += Self.pageSize
            stored = try messageRepository.fetchRecentMessages(conversationId: conversation.id, ownerUserId: me, limit: pageLimit)
        }
        return (stored, total)
    }

    func reload() {
        guard let myUserId = authService.currentUserId else { return }
        do {
            let (stored, total) = try fetchWindow(me: myUserId)
            hasOlder = total > stored.count

            // Keep read state set locally since the last fetch.
            let previous = messagesById
            messagesById = Dictionary(uniqueKeysWithValues: stored.map { message in
                var copy = message
                if copy.readAt == nil, let earlier = previous[message.id]?.readAt { copy.readAt = earlier }
                return (message.id, copy)
            })
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
            clearUnreadLine()
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
            clearUnreadLine()
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

    /// Replying means you've seen them — like WhatsApp, the line goes away.
    private func clearUnreadLine() {
        unreadAnchorId = nil
        unreadCount = 0
    }

    // MARK: Text

    func send() async {
        let text = String(draftText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(DraftStore.maxLength))
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
        if let me = authService.currentUserId {
            draftStore.clear(conversationId: conversation.id, ownerUserId: me)
        }
        replyingTo = nil
        isSending = true
        defer { isSending = false }

        do {
            try await messagingService.sendText(text, replyTo: reply, in: conversation)
            errorMessage = nil
            canRetryLastSend = false
            clearUnreadLine()
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
            if let me = authService.currentUserId {
                draftText = draftStore.load(conversationId: conversation.id, ownerUserId: me)
            } else {
                draftText = ""
            }
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
