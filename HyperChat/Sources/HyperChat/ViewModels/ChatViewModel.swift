import Foundation
import SwiftUI
import PhotosUI
import Combine

struct DisplayMessage: Identifiable {
    let id: String
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

    @Published var selectedPhotoItem: PhotosPickerItem? {
        didSet {
            guard let item = selectedPhotoItem else { return }

            Task {
                await sendPhoto(item)
            }
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
            messagesById = Dictionary(
                uniqueKeysWithValues: stored.map { ($0.id, $0) }
            )
            messages = stored.map { message in
                let mediaMetadata = messagingService.mediaDisplayMetadata(for: message)

                return DisplayMessage(
                    id: message.id,
                    isMine: message.senderId == myUserId,
                    text: messagingService.previewText(for: message),
                    contentType: message.contentType,
                    mediaType: mediaMetadata?.mediaType,
                    voiceDuration: mediaMetadata?.duration,
                    voiceWaveform: mediaMetadata?.waveform,
                    status: message.deliveryStatus,
                    createdAt: message.createdAt,
                    deliveredAt: message.deliveredAt,
                    readAt: message.readAt
                )
            }
        } catch {
            errorMessage = "Couldn't load messages: \(error.localizedDescription)"
        }
    }
    
    func loadMediaData(forMessageId messageId: String) async -> Data? {
        guard let message = messagesById[messageId] else {
            return nil
        }

        do {
            return try await messagingService.mediaData(for: message)
        } catch {
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

    /// FIX (Bug #17): re-attempts the send that failed recoverably.
    func retryLastSend() async {
        guard let draft = lastFailedDraft else { return }
        draftText = draft
        await send()
    }
    
    private func sendPhoto(_ item: PhotosPickerItem) async {
        defer {
            selectedPhotoItem = nil
        }

        guard !peerIdentityChanged else {
            errorMessage = IdentityError
                .identityChangeUnacknowledged(userId: peerId ?? "")
                .localizedDescription
            return
        }

        isSendingMedia = true
        defer {
            isSendingMedia = false
        }

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

    func sendCapturedMedia(_ capture: CameraPicker.Capture) async {
        guard !peerIdentityChanged else {
            errorMessage = IdentityError
                .identityChangeUnacknowledged(userId: peerId ?? "")
                .localizedDescription
            return
        }

        isSendingMedia = true
        defer {
            isSendingMedia = false
        }

        do {
            switch capture {
            case .photo(let data):
                try await messagingService.sendMedia(
                    rawData: data,
                    thumbnail: nil,
                    mediaType: .image,
                    in: conversation
                )

            case .video(let url):
                let data = try Data(contentsOf: url)

                try await messagingService.sendMedia(
                    rawData: data,
                    thumbnail: nil,
                    mediaType: .video,
                    in: conversation
                )
            }

            reload()

        } catch let identityError as IdentityError {
            reloadPeer()
            errorMessage = identityError.localizedDescription

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendDocument(from url: URL) async {
        guard !peerIdentityChanged else {
            errorMessage = IdentityError
                .identityChangeUnacknowledged(userId: peerId ?? "")
                .localizedDescription
            return
        }

        isSendingMedia = true
        defer {
            isSendingMedia = false
        }

        do {
            let data = try Data(contentsOf: url)

            try await messagingService.sendMedia(
                rawData: data,
                thumbnail: nil,
                mediaType: .document,
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

    func sendGIF(_ data: Data) async {
        guard !peerIdentityChanged else {
            errorMessage = IdentityError
                .identityChangeUnacknowledged(userId: peerId ?? "")
                .localizedDescription
            return
        }

        isSendingMedia = true
        defer {
            isSendingMedia = false
        }

        do {
            try await messagingService.sendMedia(
                rawData: data,
                thumbnail: nil,
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
    
    func sendVoiceMessage(_ voiceMessage: RecordedVoiceMessage) async {
        guard !peerIdentityChanged else {
            errorMessage = IdentityError
                .identityChangeUnacknowledged(userId: peerId ?? "")
                .localizedDescription
            return
        }

        isSendingMedia = true
        defer {
            isSendingMedia = false
        }

        do {
            try await messagingService.sendMedia(
                rawData: voiceMessage.data,
                thumbnail: nil,
                mediaType: .audio,
                duration: voiceMessage.duration,
                waveform: voiceMessage.normalisedWaveform(),
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
