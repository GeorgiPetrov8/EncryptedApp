import Foundation
import os

extension Notification.Name {
    static let recoveryPendingNotice = Notification.Name("SecureHyperChat.recoveryPendingNotice")
}

/// Real-time delivery over `URLSessionWebSocketTask`.
///
/// Close codes (R6):
///   4000  replaced by a newer connection of the same account → wait 60 s
///   4001  token invalid / session ended → ask for a new session, wait ≥ 5 s
///   4003  account deleted or recovered elsewhere → same notification, wait 30 s
///   other exponential back-off 1 → 30 s
///
/// NEW (#2): posts `.webSocketStateChanged` when connected/disconnected, and
/// `reconnectNow()` cuts a back-off short (used by `ConnectionMonitor` on
/// foreground and network changes).
final class RealWebSocketService: WebSocketServiceProtocol {
    private let webSocketURL: URL
    private let session: URLSession
    private let tokenStore: SessionTokenStore
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "websocket")

    private let lock = NSLock()
    private var cancelled: [String: Bool] = [:]
    private var presenceContinuation: AsyncStream<PresenceFrame>.Continuation?
    private var presenceGeneration = 0
    private var currentTask: URLSessionWebSocketTask?
    private var presenceContacts: [String] = []
    private var presenceVisible = true
    private var reconnectHandler: (@Sendable () -> Void)?
    private var wakeRequested = false

    private static let stableAfter: TimeInterval = 30

    private enum CloseCode {
        static let replaced = 4000
        static let unauthorized = 4001
        static let badAuthFrame = 4002
        static let accountGone = 4003
    }

    init(
        webSocketURL: URL = NetworkConfiguration.webSocketURL,
        tokenStore: SessionTokenStore,
        session: URLSession = .shared
    ) {
        self.webSocketURL = webSocketURL
        self.tokenStore = tokenStore
        self.session = session
    }

    // MARK: WebSocketServiceProtocol

    func events(for userId: String) -> AsyncStream<EnvelopeDTO> {
        setCancelled(false, for: userId)
        return AsyncStream { continuation in
            let task = Task {
                await self.runReconnectLoop(userId: userId, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                self?.setCancelled(true, for: userId)
                task.cancel()
            }
        }
    }

    func disconnect(userId: String) {
        setCancelled(true, for: userId)
        lock.lock()
        let task = currentTask
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        Self.postState(false)
    }

    func setReconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        reconnectHandler = handler
        lock.unlock()
    }

    func presenceFrames() -> AsyncStream<PresenceFrame> {
        AsyncStream { continuation in
            lock.lock()
            presenceContinuation?.finish()
            presenceContinuation = continuation
            presenceGeneration += 1
            let generation = presenceGeneration
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                if self.presenceGeneration == generation { self.presenceContinuation = nil }
                self.lock.unlock()
            }
        }
    }

    func updatePresence(contacts: [String], isVisible: Bool) {
        lock.lock()
        presenceContacts = contacts
        presenceVisible = isVisible
        let task = currentTask
        lock.unlock()
        guard let task else { return }
        Task { await self.sendPresenceState(on: task) }
    }

    /// Ends the current back-off wait so the loop reconnects immediately.
    func reconnectNow() {
        lock.lock()
        wakeRequested = true
        lock.unlock()
    }

    // MARK: Helpers

    private func isCancelled(_ userId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled[userId] ?? false
    }

    private func setCancelled(_ value: Bool, for userId: String) {
        lock.lock(); defer { lock.unlock() }
        cancelled[userId] = value
    }

    private func consumeWake() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = wakeRequested
        wakeRequested = false
        return value
    }

    private static func postState(_ connected: Bool) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .webSocketStateChanged, object: nil, userInfo: ["connected": connected])
        }
    }

    private static func postSessionRejected() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sessionRejectedByServer, object: nil)
        }
    }

    // MARK: Connection loop

    private enum ConnectionEnd: Error {
        case closed(code: Int, connectedFor: TimeInterval)
        case authRejected
    }

    private func runReconnectLoop(userId: String, continuation: AsyncStream<EnvelopeDTO>.Continuation) async {
        var backoff: UInt64 = 1
        var connectionCount = 0
        _ = consumeWake()

        while !isCancelled(userId) && !Task.isCancelled {
            var minimumWait: UInt64 = 0
            do {
                try await runOneConnection(userId: userId, continuation: continuation) {
                    connectionCount += 1
                    if connectionCount > 1 { self.notifyReconnected() }
                }
            } catch ConnectionEnd.authRejected {
                Self.postSessionRejected()
                minimumWait = 5
            } catch ConnectionEnd.closed(let code, let connectedFor) {
                if connectedFor >= Self.stableAfter { backoff = 1 }
                switch code {
                case CloseCode.replaced:
                    minimumWait = 60
                case CloseCode.unauthorized, CloseCode.badAuthFrame:
                    Self.postSessionRejected()
                    minimumWait = 5
                case CloseCode.accountGone:
                    Self.postSessionRejected()
                    minimumWait = 30
                default:
                    break
                }
            } catch {
                logger.error("WebSocket connection ended: \(String(describing: type(of: error)), privacy: .public)")
            }

            Self.postState(false)
            guard !isCancelled(userId) && !Task.isCancelled else { break }

            // Sleeps in 1 s steps so `reconnectNow()` can cut it short.
            let wait = max(backoff, minimumWait)
            for _ in 0..<wait {
                if consumeWake() || isCancelled(userId) || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            backoff = min(backoff * 2, 30)
        }
        continuation.finish()
    }

    private func notifyReconnected() {
        lock.lock()
        let handler = reconnectHandler
        lock.unlock()
        handler?()
    }

    private func runOneConnection(
        userId: String,
        continuation: AsyncStream<EnvelopeDTO>.Continuation,
        onAuthenticated: () -> Void
    ) async throws {
        guard let token = tokenStore.currentToken else { throw ConnectionEnd.authRejected }

        let task = session.webSocketTask(with: webSocketURL)
        task.resume()
        var connectedAt: Date?
        defer {
            task.cancel(with: .goingAway, reason: nil)
            lock.lock()
            if currentTask === task { currentTask = nil }
            lock.unlock()
        }

        do {
            try await send(task, AuthFrame(type: "auth", token: token))
            try await expectAuthOk(task)
        } catch {
            let code = task.closeCode.rawValue
            if code == CloseCode.unauthorized || code == CloseCode.badAuthFrame || code == CloseCode.accountGone {
                throw ConnectionEnd.closed(code: code, connectedFor: 0)
            }
            throw error
        }

        lock.lock()
        currentTask = task
        lock.unlock()
        connectedAt = Date()
        Self.postState(true)

        onAuthenticated()
        await sendPresenceState(on: task)

        do {
            try await receiveLoop(task, userId: userId, continuation: continuation)
        } catch {
            let code = task.closeCode.rawValue
            let duration = connectedAt.map { Date().timeIntervalSince($0) } ?? 0
            if code != URLSessionWebSocketTask.CloseCode.invalid.rawValue {
                throw ConnectionEnd.closed(code: code, connectedFor: duration)
            }
            throw error
        }
    }

    private func expectAuthOk(_ task: URLSessionWebSocketTask) async throws {
        let message = try await task.receive()
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let ack = try? SecureHyperChatJSON.decoder.decode(TypedFrame.self, from: data),
              ack.type == "authOk"
        else { throw ConnectionEnd.authRejected }
    }

    private func receiveLoop(
        _ task: URLSessionWebSocketTask,
        userId: String,
        continuation: AsyncStream<EnvelopeDTO>.Continuation
    ) async throws {
        while !isCancelled(userId) && !Task.isCancelled {
            let message = try await task.receive()
            guard case .string(let text) = message, let data = text.data(using: .utf8) else { continue }
            guard let frame = try? SecureHyperChatJSON.decoder.decode(TypedFrame.self, from: data) else { continue }

            switch frame.type {
            case "envelope":
                if let push = try? SecureHyperChatJSON.decoder.decode(EnvelopePush.self, from: data) {
                    continuation.yield(push.envelope)
                }
            case "presence":
                if let presence = try? SecureHyperChatJSON.decoder.decode(PresenceFrame.self, from: data) {
                    lock.lock()
                    let presenceContinuation = self.presenceContinuation
                    lock.unlock()
                    presenceContinuation?.yield(presence)
                }
            case "notice":
                if let notice = try? JSONDecoder().decode(NoticeFrame.self, from: data), notice.kind == "recoveryPending" {
                    let availableAt = notice.availableAt ?? ""
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .recoveryPendingNotice, object: nil, userInfo: ["availableAt": availableAt])
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: Sending

    private func sendPresenceState(on task: URLSessionWebSocketTask) async {
        lock.lock()
        let contacts = presenceContacts
        let visible = presenceVisible
        lock.unlock()
        try? await send(task, ContactsFrame(type: "contacts", userIds: contacts))
        try? await send(task, PresenceStateFrame(type: "presenceState", visible: visible))
    }

    private func send<T: Encodable>(_ task: URLSessionWebSocketTask, _ value: T) async throws {
        let data = try SecureHyperChatJSON.encoder.encode(value)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
}

private struct AuthFrame: Encodable { let type: String; let token: String }
private struct ContactsFrame: Encodable { let type: String; let userIds: [String] }
private struct PresenceStateFrame: Encodable { let type: String; let visible: Bool }
private struct TypedFrame: Decodable { let type: String }
private struct EnvelopePush: Decodable { let type: String; let envelope: EnvelopeDTO }
private struct NoticeFrame: Decodable { let type: String; let kind: String; let availableAt: String? }
