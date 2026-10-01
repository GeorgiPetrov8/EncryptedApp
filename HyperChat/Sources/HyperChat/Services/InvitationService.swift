import Foundation
import Combine
import UserNotifications
import os

/// Contact requests.
///
/// Instead of writing to someone directly, you send an invitation they must
/// accept. Rules this service enforces:
///
///   1. **The chat exists immediately for the sender**, in `invitedByMe`. You
///      can open it and write; messages are stored and shown with a clock,
///      and are transmitted the moment the other person accepts.
///   2. **Nothing but the invitation itself is transmitted before
///      acceptance.** The gate lives in `MessagingService.send` /
///      `sendControlPayload`, so it applies to chat, the shared pad, receipts,
///      profiles and calls alike.
///   3. **Both sides get told.** The recipient gets a notification for the
///      request; the sender gets one when it's accepted.
@MainActor
final class InvitationService: ObservableObject {

    @Published private(set) var pendingIncoming: [Conversation] = []

    /// Emits a conversation id whenever its relationship state changed, so
    /// lists and open chats can refresh.
    let changes = PassthroughSubject<String, Never>()

    private let conversationRepository: ConversationRepository
    private let userRepository: UserRepository
    private let messageRepository: MessageRepository
    private let authService: AuthService
    private let apiClient: APIClientProtocol
    private let logger = Logger(subsystem: "com.HyperChat", category: "invitations")

    private var sendHandler: ((InvitePayload, Conversation) async throws -> Void)?
    private var flushHandler: ((Conversation) async -> Void)?

    static let notificationCategory = "HYPERCHAT_INVITE"

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

    /// Transmits everything composed while an invitation was pending.
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

    /// Asks once; iOS never shows the prompt a second time.
    func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: Sending

    /// Looks the user up, creates the local conversation, and sends the invite.
    ///
    /// Uses the non-consuming directory lookup — an invite may never be
    /// accepted, so it mustn't burn one of their one-time prekeys. (The
    /// invite envelope itself does the X3DH handshake, which is the one
    /// prekey it legitimately needs.)
    @discardableResult
    func invite(username: String, note: String?) async throws -> Conversation {
        guard let myUserId = authService.currentUserId else { throw APIError.notAuthenticated }

        let entry = try await apiClient.fetchDirectoryEntry(username: username)
        guard entry.userId != myUserId else { throw InvitationError.cannotInviteSelf }

        if let existing = try conversationRepository.findDirectConversation(
            ownerUserId: myUserId, userA: myUserId, userB: entry.userId
        ) {
            switch existing.relationshipState {
            case .accepted:
                // Nothing to invite — hand back the existing chat.
                return existing
            case .invitedByThem:
                // They already asked us. Inviting them back means yes.
                return await accept(existing)
            case .invitedByMe, .declined:
                break // send (again)
            }
        }

        try? userRepository.upsertContactPlaceholder(
            ownerUserId: myUserId, userId: entry.userId, username: entry.username
        )

        let cleanNote = Self.clean(note)
        let participants = [myUserId, entry.userId]
        let conversation = Conversation(
            id: Conversation.deterministicId(participantIds: participants),
            ownerUserId: myUserId,
            participantIds: participants,
            isGroup: false,
            createdAt: Date(),
            relationshipState: .invitedByMe,
            inviteNote: cleanNote,
            inviteSentAt: Date()
        )
        try conversationRepository.upsert(conversation)
        changes.send(conversation.id)

        // If this throws, the chat still exists in `invitedByMe` and the user
        // can resend from inside it.
        try await transmitRequest(for: conversation)
        Task { await requestNotificationPermission() }
        return conversation
    }

    /// Sends the request again — after a failed first attempt, or after a decline.
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
            // Not fatal: the first chat message we send is treated by the other
            // side as an implicit acceptance (see MessagingService.handleIncoming).
            logger.error("Couldn't deliver the acceptance; the next message will carry it implicitly")
        }

        await flushHandler?(updated)
        return updated
    }

    /// Declines and removes the request locally, so it doesn't sit in the chat
    /// list. The sender is told, so their UI stops saying "waiting". The
    /// decline carries no note — it mustn't become a channel for a reply.
    func decline(_ conversation: Conversation) async {
        try? await sendHandler?(
            InvitePayload(kind: .decline, senderDisplayName: nil, note: nil, sentAt: Date()),
            conversation
        )
        try? conversationRepository.delete(id: conversation.id, ownerUserId: conversation.ownerUserId)
        reloadPending()
        changes.send(conversation.id)
    }

    // MARK: Incoming

    /// Applies an invite payload from a peer.
    @discardableResult
    func applyRemote(
        _ payload: InvitePayload,
        conversation: Conversation,
        senderId: String,
        ownerUserId: String
    ) -> Bool {
        var updated = conversation
        let name = senderName(senderId: senderId, ownerUserId: ownerUserId, payloadName: payload.senderDisplayName)

        switch payload.kind {
        case .request:
            switch conversation.relationshipState {
            case .accepted:
                // A request against an established chat is ignored — otherwise
                // anyone could reset it to pending by re-inviting.
                return false

            case .invitedByMe:
                // We both invited each other: that's mutual consent. Accept and
                // tell them, so both sides end up `accepted`.
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
                if let payloadName = payload.senderDisplayName {
                    try? userRepository.upsertContactPlaceholder(
                        ownerUserId: ownerUserId, userId: senderId, username: payloadName
                    )
                }
                updated.relationshipState = .invitedByThem
                updated.inviteNote = Self.clean(payload.note)
                updated.inviteSentAt = payload.sentAt
                updated.inviteRespondedAt = nil
                try? conversationRepository.upsert(updated)
                // The note is deliberately not in the notification: it's
                // end-to-end encrypted, and would otherwise show on the lock screen.
                notify(title: "New chat invitation", body: "\(name) wants to chat with you.", conversationId: updated.id)
            }

        case .accept:
            guard conversation.relationshipState == .invitedByMe || conversation.relationshipState == .declined else {
                return false
            }
            updated.relationshipState = .accepted
            updated.inviteRespondedAt = payload.sentAt
            try? conversationRepository.upsert(updated)
            let accepted = updated
            Task { await self.flushHandler?(accepted) }
            notify(title: "Invitation accepted", body: "\(name) accepted your invitation. You can chat now.", conversationId: updated.id)

        case .decline:
            guard conversation.relationshipState == .invitedByMe else { return false }
            updated.relationshipState = .declined
            updated.inviteRespondedAt = payload.sentAt
            try? conversationRepository.upsert(updated)
        }

        reloadPending()
        changes.send(updated.id)
        return true
    }

    // MARK: Helpers

    private func senderName(senderId: String, ownerUserId: String, payloadName: String?) -> String {
        if let user = try? userRepository.fetch(ownerUserId: ownerUserId, id: senderId) {
            return user.shownName
        }
        return payloadName ?? String(senderId.prefix(8))
    }

    /// Local notification. Shown in the foreground too, because
    /// `AppDelegate.willPresent` returns `.banner` for every notification.
    ///
    /// Note: a local notification can only be posted while the app is running.
    /// Getting one while the app is fully closed needs APNs push from the server.
    private func notify(title: String, body: String, conversationId: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["conversationId": conversationId]

        let request = UNNotificationRequest(
            identifier: "invite.\(conversationId).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func clean(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(InviteLimits.maxNoteLength))
    }
}

enum InvitationError: LocalizedError {
    case cannotInviteSelf
    case notAccepted
    case mustAcceptFirst
    case declined

    var errorDescription: String? {
        switch self {
        case .cannotInviteSelf:
            return "You can't invite yourself."
        case .notAccepted:
            return "This person hasn't accepted your invitation yet."
        case .mustAcceptFirst:
            return "Accept the invitation to start chatting."
        case .declined:
            return "This invitation was declined. Invite them again to chat."
        }
    }
}
