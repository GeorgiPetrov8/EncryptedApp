import Foundation
import os

/// Deletes a whole conversation from this phone (S34).
///
/// The conversation row cascades to its messages, media rows and shared-pad
/// items (composite foreign keys); the encrypted attachment files are removed
/// first, along with the chat's background override and draft. Nothing is sent
/// to the other person. The contact itself (pinned keys) stays, so if they write
/// again the chat comes back as a new request.
@MainActor
final class ConversationDeletionService {
    private let conversationRepository: ConversationRepository
    private let messageRepository: MessageRepository
    private let mediaEncryptionService: MediaEncryptionService
    private let appearanceStore: AppearanceStore
    private let draftStore: DraftStore
    private let authService: AuthService
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "conversations")

    init(
        conversationRepository: ConversationRepository,
        messageRepository: MessageRepository,
        mediaEncryptionService: MediaEncryptionService,
        appearanceStore: AppearanceStore,
        draftStore: DraftStore,
        authService: AuthService
    ) {
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.mediaEncryptionService = mediaEncryptionService
        self.appearanceStore = appearanceStore
        self.draftStore = draftStore
        self.authService = authService
    }

    func delete(conversationId: String) throws {
        guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
        let messages = try messageRepository.fetchMessages(conversationId: conversationId, ownerUserId: me)
        for message in messages where message.contentType != .text {
            try? mediaEncryptionService.deleteMedia(forMessageId: message.id, ownerUserId: me)
        }
        try conversationRepository.delete(id: conversationId, ownerUserId: me)
        appearanceStore.clearOverride(for: conversationId)
        draftStore.clear(conversationId: conversationId, ownerUserId: me)
        logger.info("Deleted a conversation with \(messages.count, privacy: .public) messages")
    }
}
