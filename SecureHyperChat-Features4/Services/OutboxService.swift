import Foundation
import Network
import Combine
import os

/// #10: sends messages that are stuck because there was no connection, by itself,
/// as soon as the connection is back — no "Retry" tap.
///
/// How a message gets here: when sending fails for a *temporary* reason (no
/// internet, timeout, server 5xx/429, expired session) `MessagingService` keeps
/// it as `.sending` (clock icon) instead of `.failed`. A permanent failure
/// (blocked, not accepted, identity changed…) is still `.failed` with the
/// Retry button — retrying those automatically would never succeed.
///
/// When it retries: on network change to "online", on WebSocket reconnect, on
/// app foreground, and on a timer with backoff 2 s → 5 → 15 → 30 → 60 → 120 →
/// 300 s (cap). Oldest message first, one at a time per chat, so order is kept.
///
/// What it never touches: messages waiting for an invitation to be accepted
/// (those also sit in `.sending`; `flushQueuedMessages` sends them on
/// acceptance), other people's messages, and a send that is still running.
/// After 72 h a message is marked `.failed` so it doesn't wait silently.
///
/// Duplicates: a retry reuses the message id. If the first attempt actually
/// reached the server (the answer got lost), the server drops the second one
/// and the other phone dedupes by id — it's shown once.
@MainActor
final class OutboxService: ObservableObject {
    @Published private(set) var isOnline = true
    /// Own messages currently waiting to be sent (for the "Waiting to send" banner).
    @Published private(set) var waitingCount = 0

    private let messageRepository: MessageRepository
    private let conversationRepository: ConversationRepository
    private let messagingService: MessagingService
    private let authService: AuthService
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "outbox")

    private let monitor = NWPathMonitor()
    private var attempts: [String: Int] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var running = false
    private var rerunRequested = false
    private var timer: Task<Void, Never>?
    /// #19: told when a message went out (removes its "scheduled" notification).
    var onSent: ((String) -> Void)?

    static let backoff: [TimeInterval] = [2, 5, 15, 30, 60, 120, 300]
    static let settleTime: TimeInterval = 5
    static let giveUpAfter: TimeInterval = 72 * 3600

    init(
        messageRepository: MessageRepository,
        conversationRepository: ConversationRepository,
        messagingService: MessagingService,
        authService: AuthService
    ) {
        self.messageRepository = messageRepository
        self.conversationRepository = conversationRepository
        self.messagingService = messagingService
        self.authService = authService
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let cameOnline = online && !self.isOnline
                self.isOnline = online
                if cameOnline {
                    // A fresh connection: don't make messages wait out their backoff.
                    self.lastAttempt.removeAll()
                    self.flush()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.securehyperchat.outbox.path"))
        flush()
    }

    /// Call on reconnect, app foreground, account switch, and after a transient
    /// failure. Cheap: does nothing when nothing is waiting.
    func flush() {
        if running {
            rerunRequested = true
            return
        }
        Task { await run() }
    }

    func reset() {
        timer?.cancel()
        attempts.removeAll()
        lastAttempt.removeAll()
        waitingCount = 0
    }

    // MARK: Work

    private func run() async {
        guard let me = authService.currentUserId, authService.isStorageUnlocked else { return }
        running = true
        defer {
            running = false
            if rerunRequested {
                rerunRequested = false
                flush()
            }
        }

        let waiting = (try? messageRepository.fetchUnsent(ownerUserId: me)) ?? []
        let conversations = Dictionary(
            ((try? conversationRepository.fetchAllSortedByRecentActivity(ownerUserId: me)) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let now = Date()

        var due: [(Message, Conversation)] = []
        var counted = 0
        for message in waiting.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let conversation = conversations[message.conversationId],
                  conversation.relationshipState == .accepted else { continue }
            // #19: a scheduled message whose time hasn't come isn't waiting yet.
            if let scheduled = message.scheduledFor, scheduled > now { continue }
            counted += 1
            guard isOnline, !messagingService.isInFlight(message.id) else { continue }
            let age = now.timeIntervalSince(message.createdAt)
            guard age >= Self.settleTime else { continue }
            if age > Self.giveUpAfter {
                try? messageRepository.updateDeliveryStatus(messageId: message.id, ownerUserId: me, status: .failed)
                messagingService.conversationChanged.send(conversation.id)
                forget(message.id)
                continue
            }
            if let count = attempts[message.id], count > 0, let last = lastAttempt[message.id],
               now.timeIntervalSince(last) < Self.delay(afterAttempts: count) { continue }
            due.append((message, conversation))
        }
        waitingCount = counted

        // One chat at a time, oldest first inside it: order is preserved and a
        // failure stops the rest of that chat until the next round.
        var blockedChats = Set<String>()
        for (message, conversation) in due where !blockedChats.contains(conversation.id) {
            attempts[message.id, default: 0] += 1
            lastAttempt[message.id] = Date()
            do {
                try await messagingService.retry(messageId: message.id, in: conversation)
                forget(message.id)
                onSent?(message.id)
                waitingCount = max(0, waitingCount - 1)
            } catch {
                blockedChats.insert(conversation.id)
                if !Self.isTransient(error) {
                    // `MessagingService` already marked it `.failed`.
                    forget(message.id)
                    waitingCount = max(0, waitingCount - 1)
                }
            }
        }

        scheduleTimer(hasWaiting: waitingCount > 0)
    }

    private func scheduleTimer(hasWaiting: Bool) {
        timer?.cancel()
        guard hasWaiting, isOnline else { return }
        let nextIn = attempts.values.map { Self.delay(afterAttempts: $0) }.min() ?? Self.backoff[0]
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(nextIn, Self.settleTime) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func forget(_ id: String) {
        attempts[id] = nil
        lastAttempt[id] = nil
    }

    nonisolated static func delay(afterAttempts count: Int) -> TimeInterval {
        backoff[min(max(count - 1, 0), backoff.count - 1)]
    }

    // MARK: Classification

    /// Temporary failures that are worth retrying by themselves.
    nonisolated static func isTransient(_ error: Error) -> Bool {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
                 .dataNotAllowed, .callIsActive, .secureConnectionFailed, .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        if case NetworkError.server(let status, _, _) = error {
            return status == 0 || status == 401 || status == 408 || status == 429 || status >= 500
        }
        if case APIError.notAuthenticated = error { return true }
        return false
    }
}
