import Foundation
import Combine
import UserNotifications
import os

/// Contact requests.
///
///   1. The chat exists immediately for the sender, in `invitedByMe`.
///   2. Nothing but the invitation itself is transmitted before acceptance.
///   3. Both sides get told.
///
/// FIX (S1): the name in an invitation is no longer trusted. The banner and the
/// notification use the username from the server directory (looked up by
/// `MessagingService` before this runs). Before, a stranger could invite you as
/// "Bank Support" or as one of your friends.
///
/// FIX (S34): declining can block. A blocked user's later invitations and
/// messages are dropped silently (see `BlockListStore`, `MessagingService`).
@MainActor
final class InvitationService: ObservableObject {

    @Published private(set) var pendingIncoming: [Conversation] = []

    let changes = PassthroughSubject<String, Never>()

    private let conversationRepository: ConversationRepository
    private let userRepository: UserRepository
    private let messageRepository: MessageRepository
    private let authService: AuthService
    private let apiClient: APIClientProtocol
    let blockList: BlockListStore
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "invitations")

    private var sendHandler: ((InvitePayload, Conversation) async throws -> Void)?
    private var flushHandler: ((Conversation) async -> Void)?

    static let notificationCategory = "HYPERCHAT_INVITE"

    init(
        conversationRepository: ConversationRepository,
        userRepository: UserRepository,
        messageRepository: MessageRepository,
        authService: AuthService,
        apiClient: APIClientProtocol,
        blockList: BlockListStore = BlockListStore()
    ) {
        self.conversationRepository = conversationRepository
        self.userRepository = userRepository
        self.messageRepository = messageRepository
        self.authService = authService
        self.apiClient = apiClient
        self.blockList = blockList
    }

    func setSendHandler(_ handler: @escaping (InvitePayload, Conversation) async throws -> Void) {
        sendHandler = handler
    }

    func setFlushHandler(_ handler: @escaping (Conversation) async -> Void) {
        flushHandler = handler
    }

    var pendingCount: Int { pendingIncoming.count }

    func reloadPending() {
        guard let myUserId = authService.currentUserId else {
            pendingIncoming = []
            return
        }
        pendingIncoming = (try? conversationRepository.fetchAll(
            ownerUserId: myUserId, relationshipState: .invitedByThem
        )) ?? []
    }

    func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: Sending

    @discardableResult
    func invite(username: String, note: String?) async throws -> Conversation {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }

        let entry = try await apiClient.fetchDirectoryEntry(username: username)
        guard entry.userId != myUserId else { throw InvitationError.cannotInviteSelf }

        // Inviting someone you blocked unblocks them — that's an explicit choice.
        blockList.unblock(entry.userId, ownerUserId: myUserId)

        if let existing = try conversationRepository.findDirectConversation(
            ownerUserId: myUserId, userA: myUserId, userB: entry.userId
        ) {
            switch existing.relationshipState {
            case .accepted:
                return existing
            case .invitedByThem:
                return await accept(existing)
            case .invitedByMe, .declined:
                break
            }
        }

        // From the directory, so trustworthy.
        try? userRepository.upsertContactPlaceholder(
            ownerUserId: myUserId, userId: entry.userId, username: entry.username
        )

        let participants = [myUserId, entry.userId]
        let conversation = Conversation(
            id: Conversation.deterministicId(participantIds: participants),
            ownerUserId: myUserId,
            participantIds: participants,
            isGroup: false,
            createdAt: Date(),
            relationshipState: .invitedByMe,
            inviteNote: Self.clean(note),
            inviteSentAt: Date()
        )
        try conversationRepository.upsert(conversation)
        changes.send(conversation.id)

        try await transmitRequest(for: conversation)
        Task { await requestNotificationPermission() }
        return conversation
    }

    func resend(_ conversation: Conversation) async throws {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }
        var updated = (try? conversationRepository.fetch(id: conversation.id, ownerUserId: myUserId)) ?? conversation
        guard updated.relationshipState == .invitedByMe || updated.relationshipState == .declined else { return }
        updated.relationshipState = .invitedByMe
        updated.inviteSentAt = Date()
        updated.inviteRespondedAt = nil
        try conversationRepository.upsert(updated)
        changes.send(updated.id)
        try await transmitRequest(for: updated)
    }

    private func transmitRequest(for conversation: Conversation) async throws {
        let payload = InvitePayload(
            kind: .request,
            senderDisplayName: authService.currentUsername,
            note: conversation.inviteNote,
            sentAt: Date()
        )
        try await sendHandler?(payload, conversation)
    }

    // MARK: Responding

    @discardableResult
    func accept(_ conversation: Conversation) async -> Conversation {
        var updated = conversation
        updated.relationshipState = .accepted
        updated.inviteRespondedAt = Date()
        try? conversationRepository.upsert(updated)
        reloadPending()
        changes.send(updated.id)

        do {
            try await sendHandler?(
                InvitePayload(kind: .accept, senderDisplayName: authService.currentUsername, note: nil, sentAt: Date()),
                updated
            )
        } catch {
            logger.error("Couldn't deliver the acceptance; the next message will carry it implicitly")
        }

        await flushHandler?(updated)
        return updated
    }

    /// Declines and removes the request locally. With `block: true` the sender
    /// can't invite or message again until you invite them yourself; no decline is
    /// sent to them in that case (it would only tell them to try another account).
    func decline(_ conversation: Conversation, block: Bool = false) async {
        if block, let me = authService.currentUserId,
           let peerId = conversation.otherParticipant(myUserId: me) {
            blockList.block(peerId, ownerUserId: me)
        } else {
            try? await sendHandler?(
                InvitePayload(kind: .decline, senderDisplayName: nil, note: nil, sentAt: Date()),
                conversation
            )
        }
        try? conversationRepository.delete(id: conversation.id, ownerUserId: conversation.ownerUserId)
        reloadPending()
        changes.send(conversation.id)
    }

    // MARK: Incoming

    @discardableResult
    func applyRemote(
        _ payload: InvitePayload,
        conversation: Conversation,
        senderId: String,
        ownerUserId: String
    ) -> Bool {
        if blockList.isBlocked(senderId, ownerUserId: ownerUserId) { return false }

        var updated = conversation
        let name = senderName(senderId: senderId, ownerUserId: ownerUserId)

        switch payload.kind {
        case .request:
            switch conversation.relationshipState {
            case .accepted:
                return false

            case .invitedByMe:
                updated.relationshipState = .accepted
                updated.inviteRespondedAt = Date()
                try? conversationRepository.upsert(updated)
                let accepted = updated
                Task {
                    try? await self.sendHandler?(
                        InvitePayload(kind: .accept, senderDisplayName: self.authService.currentUsername, note: nil, sentAt: Date()),
                        accepted
                    )
                    await self.flushHandler?(accepted)
                }
                notify(title: "You're connected", body: "\(name) also invited you. You can chat now.", conversationId: updated.id)

            case .invitedByThem, .declined:
                // The name in the payload is deliberately NOT stored (S1).
                updated.relationshipState = .invitedByThem
                updated.inviteNote = Self.clean(payload.note)
                updated.inviteSentAt = min(payload.sentAt, Date())
                updated.inviteRespondedAt = nil
                try? conversationRepository.upsert(updated)
                notify(title: "New chat invitation", body: "\(name) wants to chat with you.", conversationId: updated.id)
            }

        case .accept:
            guard conversation.relationshipState == .invitedByMe || conversation.relationshipState == .declined else {
                return false
            }
            updated.relationshipState = .accepted
            updated.inviteRespondedAt = min(payload.sentAt, Date())
            try? conversationRepository.upsert(updated)
            let accepted = updated
            Task { await self.flushHandler?(accepted) }
            notify(title: "Invitation accepted", body: "\(name) accepted your invitation. You can chat now.", conversationId: updated.id)

        case .decline:
            guard conversation.relationshipState == .invitedByMe else { return false }
            updated.relationshipState = .declined
            updated.inviteRespondedAt = min(payload.sentAt, Date())
            try? conversationRepository.upsert(updated)
        }

        reloadPending()
        changes.send(updated.id)
        return true
    }

    // MARK: Helpers

    /// The directory username; never the name inside the invitation.
    private func senderName(senderId: String, ownerUserId: String) -> String {
        if let user = try? userRepository.fetch(ownerUserId: ownerUserId, id: senderId),
           !user.hasPlaceholderUsername {
            return user.shownName
        }
        return "Someone (\(senderId.prefix(8)))"
    }

    private func notify(title: String, body: String, conversationId: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["conversationId": conversationId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "invite.\(conversationId).\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    /// Notes are shown in the invitation banner: cleaned of control and bidi
    /// characters as well as trimmed.
    private static func clean(_ note: String?) -> String? {
        SafeText.line(note, maxLength: InviteLimits.maxNoteLength)
    }
}

enum InvitationError: LocalizedError {
    case cannotInviteSelf
    case notAccepted
    case mustAcceptFirst
    case declined

    var errorDescription: String? {
        switch self {
        case .cannotInviteSelf: return "You can't invite yourself."
        case .notAccepted: return "This person hasn't accepted your invitation yet."
        case .mustAcceptFirst: return "Accept the invitation to start chatting."
        case .declined: return "This invitation was declined. Invite them again to chat."
        }
    }
}
