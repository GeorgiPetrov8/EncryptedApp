import Foundation
import Combine
import os

/// Contact requests (feature #6).
///
/// Replaces "type a username and start writing" with "send an invitation they
/// must accept". Two consequences the design has to get right:
///
///   1. **The chat exists immediately for the sender.** That was the explicit
///      requirement — you see the conversation you started, not a void until
///      they reply. So a conversation row is created locally in
///      `invitedByMe` and shows in the list, with messages composable and
///      queued.
///
///   2. **Nothing is transmitted until acceptance.** Otherwise the invite is
///      decorative: an unsolicited message would reach them anyway, which is
///      exactly what the feature is meant to prevent. Queued messages are held
///      locally and flushed on acceptance.
@MainActor
final class InvitationService: ObservableObject {

    @Published private(set) var pendingIncoming: [Conversation] = []

    private let conversationRepository: ConversationRepository
    private let userRepository: UserRepository
    private let messageRepository: MessageRepository
    private let authService: AuthService
    private let apiClient: APIClientProtocol
    private let logger = Logger(subsystem: "com.HyperChat", category: "invitations")

    private var sendHandler: ((InvitePayload, Conversation) async throws -> Void)?
    private var flushHandler: ((Conversation) async -> Void)?

    init(
        conversationRepository: ConversationRepository,
        userRepository: UserRepository,
        messageRepository: MessageRepository,
        authService: AuthService,
        apiClient: APIClientProtocol
    ) {
        self.conversationRepository = conversationRepository
        self.userRepository = userRepository
        self.messageRepository = messageRepository
        self.authService = authService
        self.apiClient = apiClient
    }

    func setSendHandler(_ handler: @escaping (InvitePayload, Conversation) async throws -> Void) {
        sendHandler = handler
    }

    /// Called after an invite is accepted, to transmit everything composed
    /// while it was pending.
    func setFlushHandler(_ handler: @escaping (Conversation) async -> Void) {
        flushHandler = handler
    }

    func reloadPending() {
        guard let myUserId = authService.currentUserId else { return }
        pendingIncoming = (try? conversationRepository.fetchAll(
            ownerUserId: myUserId, relationshipState: .invitedByThem
        )) ?? []
    }

    var pendingCount: Int { pendingIncoming.count }

    // MARK: Sending

    /// Looks the user up, creates the local conversation, and sends the invite.
    ///
    /// The directory lookup is the non-consuming one — inviting someone must
    /// not burn a one-time prekey, since an invite may never be accepted and
    /// those keys are a finite resource per contact.
    @discardableResult
    func invite(username: String, note: String?) async throws -> Conversation {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }

        let entry = try await apiClient.fetchDirectoryEntry(username: username)

        guard entry.userId != myUserId else {
            throw InvitationError.cannotInviteSelf
        }

        // An existing accepted conversation means there's nothing to invite —
        // hand back the existing thread rather than resetting it to pending,
        // which would lock the user out of their own history.
        if let existing = try conversationRepository.findDirectConversation(
            ownerUserId: myUserId, userA: myUserId, userB: entry.userId
        ), existing.relationshipState.allowsSending {
            return existing
        }

        try? userRepository.upsertContactPlaceholder(
            ownerUserId: myUserId, userId: entry.userId, username: entry.username
        )

        let participants = [myUserId, entry.userId]
        var conversation = Conversation(
            id: Conversation.deterministicId(participantIds: participants),
            ownerUserId: myUserId,
            participantIds: participants,
            isGroup: false,
            createdAt: Date()
        )
        conversation.relationshipState = .invitedByMe
        conversation.inviteSentAt = Date()
        conversation.inviteNote = note
        try conversationRepository.upsert(conversation)

        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = InvitePayload(
            kind: .request,
            senderDisplayName: authService.currentUsername,
            note: trimmedNote.map { String($0.prefix(InviteLimits.maxNoteLength)) },
            sentAt: Date()
        )

        // The invite itself *is* transmitted despite the conversation being
        // pending — it's the one payload that must cross before acceptance,
        // and it's what the server's own invite allowance is scoped to.
        try await sendHandler?(payload, conversation)
        return conversation
    }

    // MARK: Responding

    func accept(_ conversation: Conversation) async {
        guard let myUserId = authService.currentUserId else { return }
        var updated = conversation
        updated.relationshipState = .accepted
        updated.inviteRespondedAt = Date()
        try? conversationRepository.upsert(updated)

        let payload = InvitePayload(
            kind: .accept,
            senderDisplayName: authService.currentUsername,
            note: nil,
            sentAt: Date()
        )
        try? await sendHandler?(payload, updated)

        reloadPending()
        // Anything we composed while waiting now goes out.
        await flushHandler?(updated)
        _ = myUserId
    }

    func decline(_ conversation: Conversation) async {
        var updated = conversation
        updated.relationshipState = .declined
        updated.inviteRespondedAt = Date()
        try? conversationRepository.upsert(updated)

        // The decline is told to the sender so their UI stops saying
        // "waiting". Silence would leave them watching a request forever.
        // It carries no note and no reason — a decline shouldn't be a channel
        // for an unsolicited message back.
        let payload = InvitePayload(
            kind: .decline,
            senderDisplayName: nil,
            note: nil,
            sentAt: Date()
        )
        try? await sendHandler?(payload, updated)
        reloadPending()
    }

    // MARK: Incoming

    /// Applies an invite payload from a peer.
    ///
    /// - Returns: whether this changed anything worth notifying about.
    @discardableResult
    func applyRemote(
        _ payload: InvitePayload,
        conversation: Conversation,
        senderId: String,
        ownerUserId: String
    ) -> Bool {
        var updated = conversation

        switch payload.kind {
        case .request:
            // A request against an already-accepted conversation is ignored
            // rather than reverting it to pending — otherwise anyone could
            // reset an established chat by re-inviting.
            guard !conversation.relationshipState.allowsSending else { return false }
            // A previously declined invite can be re-sent; that's deliberate,
            // since people do change their minds and block is a separate
            // concept. Rate limiting for this lives on the server.
            updated.relationshipState = .invitedByThem
            updated.inviteNote = payload.note
            updated.inviteSentAt = payload.sentAt
            if let name = payload.senderDisplayName {
                try? userRepository.upsertContactPlaceholder(
                    ownerUserId: ownerUserId, userId: senderId, username: name
                )
            }

        case .accept:
            guard conversation.relationshipState == .invitedByMe else { return false }
            updated.relationshipState = .accepted
            updated.inviteRespondedAt = payload.sentAt
            Task { await flushHandler?(updated) }

        case .decline:
            guard conversation.relationshipState == .invitedByMe else { return false }
            updated.relationshipState = .declined
            updated.inviteRespondedAt = payload.sentAt
        }

        try? conversationRepository.upsert(updated)
        reloadPending()
        return true
    }
}

enum InvitationError: LocalizedError {
    case cannotInviteSelf
    case notAccepted

    var errorDescription: String? {
        switch self {
        case .cannotInviteSelf:
            return "You can't invite yourself."
        case .notAccepted:
            return "This person hasn't accepted your invitation yet. Your messages will send as soon as they do."
        }
    }
}
