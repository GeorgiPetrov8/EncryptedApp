import Foundation
import Combine
import os

/// Tracks which contacts are currently in the app.
///
/// Goes through the server rather than end-to-end: the server already knows
/// who holds an open socket. What's controlled is *who it tells* — only
/// mutual, accepted contacts, and only while this user is visible (app in the
/// foreground AND "show when I'm online" on). Both are enforced server-side.
///
/// When someone isn't online, **nothing** is shown — no "last seen".
///
/// FIX: this service existed but was never constructed or started, its
/// transport hooks were protocol-extension no-ops, and it never told the
/// server who its contacts were — so the server had nobody to report.
@MainActor
final class PresenceService: ObservableObject {
    /// User ids currently online.
    @Published private(set) var onlineUserIds: Set<String> = []

    /// Whether this user broadcasts their own presence.
    @Published var isSharingPresence: Bool {
        didSet {
            UserDefaults.standard.set(isSharingPresence, forKey: Keys.sharing)
            pushState()
        }
    }

    private let webSocketService: WebSocketServiceProtocol
    private let authService: AuthService
    private let conversationRepository: ConversationRepository
    private let logger = Logger(subsystem: "com.HyperChat", category: "presence")

    private var listenerTask: Task<Void, Never>?
    private var contacts: [String] = []
    private var isAppActive = true

    private enum Keys {
        static let sharing = "presence.isSharing"
    }

    init(
        webSocketService: WebSocketServiceProtocol,
        authService: AuthService,
        conversationRepository: ConversationRepository
    ) {
        self.webSocketService = webSocketService
        self.authService = authService
        self.conversationRepository = conversationRepository
        self.isSharingPresence = (UserDefaults.standard.object(forKey: Keys.sharing) as? Bool) ?? true
    }

    // MARK: Lifecycle

    /// Call **before** `MessagingService.startListening()` — the presence stream
    /// must exist before the socket connects, or the snapshot the server sends
    /// right after authentication has nowhere to go.
    func start() {
        listenerTask?.cancel()
        onlineUserIds = []
        let frames = webSocketService.presenceFrames()
        listenerTask = Task { [weak self] in
            for await frame in frames {
                self?.apply(frame)
            }
        }
        refreshContacts()
    }

    func stop() {
        listenerTask?.cancel()
        listenerTask = nil
        contacts = []
        onlineUserIds = []
    }

    /// Foreground/background, from the App's `scenePhase`.
    func setAppActive(_ active: Bool) {
        guard isAppActive != active else { return }
        isAppActive = active
        pushState()
    }

    /// Re-reads which peers we have accepted conversations with. Call when a
    /// conversation appears or an invitation is accepted.
    func refreshContacts() {
        guard let myUserId = authService.currentUserId else { return }
        do {
            let conversations = try conversationRepository.fetchAllSortedByRecentActivity(ownerUserId: myUserId)
            let peers = conversations
                .filter { $0.relationshipState.allowsSending }
                .compactMap { $0.otherParticipant(myUserId: myUserId) }
            let unique = Array(Set(peers)).sorted()
            guard unique != contacts else { return }
            contacts = unique
            pushState()
        } catch {
            logger.error("Couldn't read conversations for presence")
        }
    }

    func isOnline(_ userId: String) -> Bool {
        onlineUserIds.contains(userId)
    }

    // MARK: Private

    private func pushState() {
        guard authService.currentUserId != nil else { return }
        webSocketService.updatePresence(
            contacts: contacts,
            isVisible: isSharingPresence && isAppActive
        )
    }

    private func apply(_ frame: PresenceFrame) {
        switch frame.kind {
        case .snapshot:
            onlineUserIds = Set(frame.userIds)
        case .online:
            onlineUserIds.formUnion(frame.userIds)
        case .offline:
            onlineUserIds.subtract(frame.userIds)
        }
    }
}

/// A presence update from the server.
struct PresenceFrame: Codable, Equatable {
    enum Kind: String, Codable {
        case snapshot
        case online
        case offline
    }

    let kind: Kind
    let userIds: [String]
}

// NOTE: the protocol extension with no-op `sendPresencePreference` /
// `presenceFrames` that used to live here is intentionally gone — those are
// now real requirements on `WebSocketServiceProtocol`.
