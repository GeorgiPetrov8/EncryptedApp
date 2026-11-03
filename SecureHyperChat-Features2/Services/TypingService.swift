import Foundation
import Combine

/// #3: "typing…".
///
/// Sending: `draftChanged(in:peerId:)` on every edit of the composer. A "start"
/// goes out at most every 3 s while you type; a "stop" after 4 s without a
/// keystroke, when the draft is emptied or sent, and when the chat closes.
///
/// Receiving: a contact counts as typing until their "stop", or 6 s after the
/// last "start" (in case the "stop" was lost — e.g. their app was killed).
///
/// Never sent to a chat that isn't accepted, nor while "Show when I'm online"
/// is off (typing would reveal activity just like the online dot).
@MainActor
final class TypingService: ObservableObject {
    @Published private(set) var typingPeers: Set<String> = []

    private let webSocket: WebSocketServiceProtocol
    private let presence: PresenceService

    private var sentStartAt: [String: Date] = [:]
    private var stopTasks: [String: Task<Void, Never>] = [:]
    private var expiryTasks: [String: Task<Void, Never>] = [:]

    private static let resendInterval: TimeInterval = 3
    private static let idleStop: UInt64 = 4_000_000_000
    private static let receiveTimeout: UInt64 = 6_000_000_000

    init(webSocket: WebSocketServiceProtocol, presence: PresenceService) {
        self.webSocket = webSocket
        self.presence = presence
    }

    func isTyping(_ peerId: String) -> Bool { typingPeers.contains(peerId) }

    // MARK: Sending

    func draftChanged(_ text: String, peerId: String, canSend: Bool) {
        guard canSend, presence.isSharingPresence else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stopped(peerId: peerId)
            return
        }
        let now = Date()
        if now.timeIntervalSince(sentStartAt[peerId] ?? .distantPast) >= Self.resendInterval {
            sentStartAt[peerId] = now
            webSocket.sendEphemeral(.typing(to: peerId, isTyping: true))
        }
        stopTasks[peerId]?.cancel()
        stopTasks[peerId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleStop)
            guard !Task.isCancelled else { return }
            self?.stopped(peerId: peerId)
        }
    }

    /// After sending, on clearing the draft, and when the chat closes.
    func stopped(peerId: String) {
        stopTasks[peerId]?.cancel()
        stopTasks[peerId] = nil
        guard sentStartAt.removeValue(forKey: peerId) != nil else { return }
        webSocket.sendEphemeral(.typing(to: peerId, isTyping: false))
    }

    // MARK: Receiving

    func apply(from peerId: String, isTyping: Bool) {
        expiryTasks[peerId]?.cancel()
        guard isTyping else {
            typingPeers.remove(peerId)
            return
        }
        typingPeers.insert(peerId)
        expiryTasks[peerId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.receiveTimeout)
            guard !Task.isCancelled else { return }
            self?.typingPeers.remove(peerId)
        }
    }

    /// A new message from them means they stopped typing.
    func messageArrived(from peerId: String) {
        apply(from: peerId, isTyping: false)
    }

    func reset() {
        for task in stopTasks.values { task.cancel() }
        for task in expiryTasks.values { task.cancel() }
        stopTasks.removeAll()
        expiryTasks.removeAll()
        sentStartAt.removeAll()
        typingPeers.removeAll()
    }
}
