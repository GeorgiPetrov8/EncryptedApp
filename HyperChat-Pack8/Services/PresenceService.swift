import Foundation
import Combine
import os

/// Tracks which contacts are currently in the app.
///
/// ## Why this goes through the server rather than end-to-end
///
/// Every other payload in this app is encrypted so the server learns nothing.
/// Presence is the exception, and deliberately so: the server *already* knows
/// who holds an open WebSocket — that's how live delivery works at all. Routing
/// presence peer-to-peer would encrypt a fact the server can observe directly
/// by looking at its own connection table, which buys no privacy and costs a
/// ratchet step per status change.
///
/// What *is* worth controlling is who the server tells. A user only appears
/// online to accepted contacts, and only if they haven't turned presence off —
/// both enforced server-side, since a client-side filter would be cosmetic.
///
/// ## Matching the WhatsApp behaviour that was asked for
///
/// Online shows while the app is foregrounded. When it isn't, **nothing** is
/// shown — not "last seen 10 minutes ago". That was the explicit request, and
/// it's also the better default: a last-seen timestamp is a surprisingly
/// sensitive signal (it reveals sleep schedules and daily routine) and is the
/// single most-regretted feature in most messengers that shipped it.
@MainActor
final class PresenceService: ObservableObject {

    /// User ids currently online. Absence means "not online", which the UI
    /// renders as nothing at all rather than as "offline".
    @Published private(set) var onlineUserIds: Set<String> = []

    /// Whether this user broadcasts their own presence. Local preference,
    /// pushed to the server, which stops telling anyone when it's off.
    @Published var isSharingPresence: Bool {
        didSet {
            UserDefaults.standard.set(isSharingPresence, forKey: Keys.sharing)
            Task { await pushPreference() }
        }
    }

    private let webSocketService: WebSocketServiceProtocol
    private let authService: AuthService
    private let logger = Logger(subsystem: "com.HyperChat", category: "presence")
    private var listenerTask: Task<Void, Never>?

    private enum Keys {
        static let sharing = "presence.isSharing"
    }

    init(webSocketService: WebSocketServiceProtocol, authService: AuthService) {
        self.webSocketService = webSocketService
        self.authService = authService
        // Defaults to on, matching the messengers users are coming from.
        // `object(forKey:)` rather than `bool(forKey:)` so "never set" is
        // distinguishable from "explicitly set to false".
        self.isSharingPresence = (UserDefaults.standard.object(forKey: Keys.sharing) as? Bool) ?? true
    }

    /// Begins consuming presence frames.
    ///
    /// Reuses the existing socket instead of opening a second one — a separate
    /// presence connection would double the server's connection count and, on
    /// mobile, roughly double the radio wake-ups.
    func start(onPresenceFrame stream: AsyncStream<PresenceFrame>) {
        listenerTask?.cancel()
        listenerTask = Task { [weak self] in
            for await frame in stream {
                await self?.apply(frame)
            }
        }
        Task { await pushPreference() }
    }

    func stop() {
        listenerTask?.cancel()
        listenerTask = nil
        // Cleared on stop so a signed-out account's contacts don't linger as
        // "online" behind the login screen.
        onlineUserIds = []
    }

    func isOnline(_ userId: String) -> Bool {
        onlineUserIds.contains(userId)
    }

    private func apply(_ frame: PresenceFrame) {
        switch frame.kind {
        case .snapshot:
            // Sent once on connect: the authoritative set, which also corrects
            // any drift from missed deltas during a flaky connection.
            onlineUserIds = Set(frame.userIds)
        case .online:
            onlineUserIds.formUnion(frame.userIds)
        case .offline:
            onlineUserIds.subtract(frame.userIds)
        }
    }

    private func pushPreference() async {
        guard authService.currentUserId != nil else { return }
        webSocketService.sendPresencePreference(isSharing: isSharingPresence)
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

extension WebSocketServiceProtocol {
    /// Default no-op so the mock transport — which has no presence concept —
    /// still satisfies the protocol without every implementation having to
    /// care about presence.
    func sendPresencePreference(isSharing: Bool) {}
    func presenceFrames() -> AsyncStream<PresenceFrame> {
        AsyncStream { $0.finish() }
    }
}
