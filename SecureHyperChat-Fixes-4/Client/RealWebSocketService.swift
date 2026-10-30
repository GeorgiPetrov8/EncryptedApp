import Foundation
import os

extension Notification.Name {
    /// The server says someone started recovering this account on another
    /// device (server v2, S2). `userInfo["availableAt"]` is an ISO-8601 string.
    static let recoveryPendingNotice = Notification.Name("SecureHyperChat.recoveryPendingNotice")
}

/// Real-time delivery over `URLSessionWebSocketTask`.
///
/// Authentication is the first message after the socket opens, not a URL
/// query parameter (which would end up in proxy access logs).
///
/// FIX (R6): the server's close codes are now told apart.
///
///   4000  replaced by a newer connection of the same account (another device,
///         or a restored backup on a second phone). Reconnecting after 1 s
///         made two devices kick each other out every second and made presence
///         flicker. Now the loser waits 60 s before trying again.
///   4001  token invalid / session ended / auth refused → ask
///         `SessionRenewalService` for a fresh token (`.sessionRejectedByServer`)
///         and wait at least 5 s.
///   4003  account deleted or recovered elsewhere → same notification (renewal
///         then signs the user out if the keys no longer match), wait 30 s.
///   other normal exponential backoff (1 → 30 s).
///
/// The backoff is reset only after a connection has stayed up for 30 s, so a
/// server that accepts and immediately drops us doesn't produce a tight loop.
final class RealWebSocketService: WebSocketServiceProtocol {
    private let webSocketURL: URL
    private let session: URLSession
    private let tokenStore: SessionTokenStore
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "websocket")

    /// All guarded by `lock`.
    private let lock = NSLock()
    private var cancelled: [String: Bool] = [:]
    private var presenceContinuation: AsyncStream<PresenceFrame>.Continuation?
    private var presenceGeneration = 0
    private var currentTask: URLSessionWebSocketTask?
    private var presenceContacts: [String] = []
    private var presenceVisible = true
    private var reconnectHandler: (@Sendable () -> Void)?

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
                if self.presenceGeneration == generation {
                    self.presenceContinuation = nil
                }
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

    // MARK: Cancellation

    private func isCancelled(_ userId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled[userId] ?? false
    }

    private func setCancelled(_ value: Bool, for userId: String) {
        lock.lock(); defer { lock.unlock() }
        cancelled[userId] = value
    }

    // MARK: Connection loop

    private enum ConnectionEnd: Error {
        case closed(code: Int, connectedFor: TimeInterval)
        case authRejected
    }

    private func runReconnectLoop(userId: String, continuation: AsyncStream<EnvelopeDTO>.Continuation) async {
        var backoff: UInt64 = 1
        var connectionCount = 0

        while !isCancelled(userId) && !Task.isCancelled {
            var minimumWait: UInt64 = 0
            do {
                try await runOneConnection(userId: userId, continuation: continuation) {
                    connectionCount += 1
                    if connectionCount > 1 { self.notifyReconnected() }
                }
            } catch ConnectionEnd.authRejected {
                logger.error("WebSocket authentication rejected; asking for a new session")
                Self.postSessionRejected()
                minimumWait = 5
            } catch ConnectionEnd.closed(let code, let connectedFor) {
                if connectedFor >= Self.stableAfter { backoff = 1 }
                switch code {
                case CloseCode.replaced:
                    logger.info("Another connection of this account took over; waiting before reconnecting")
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

            guard !isCancelled(userId) && !Task.isCancelled else { break }
            let wait = max(backoff, minimumWait)
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            backoff = min(backoff * 2, 30)
        }
        continuation.finish()
    }

    private static func postSessionRejected() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sessionRejectedByServer, object: nil)
        }
    }

    private func notifyReconnected() {
        lock.lock()
        let handler = reconnectHandler
        lock.unlock()
        logger.info("WebSocket reconnected; requesting backfill")
        handler?()
    }

    private func runOneConnection(
        userId: String,
        continuation: AsyncStream<EnvelopeDTO>.Continuation,
        onAuthenticated: () -> Void
    ) async throws {
        guard let token = tokenStore.currentToken else {
            throw ConnectionEnd.authRejected
        }

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
            // The server answers a bad token with close code 4001; anything
            // else (network) is an ordinary failure.
            let code = task.closeCode.rawValue
            if code == CloseCode.unauthorized || code == CloseCode.badAuthFrame || code == CloseCode.accountGone {
                throw ConnectionEnd.closed(code: code, connectedFor: 0)
            }
            if error is ConnectionEnd { throw error }
            throw error
        }

        lock.lock()
        currentTask = task
        lock.unlock()
        connectedAt = Date()

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
        else {
            throw ConnectionEnd.authRejected
        }
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
                if let notice = try? JSONDecoder().decode(NoticeFrame.self, from: data),
                   notice.kind == "recoveryPending" {
                    let availableAt = notice.availableAt ?? ""
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .recoveryPendingNotice, object: nil,
                            userInfo: ["availableAt": availableAt]
                        )
                    }
                }
            default:
                logger.debug("Ignoring WebSocket frame of type \(frame.type, privacy: .public)")
            }
        }
    }

    // MARK: Sending

    private func sendPresenceState(on task: URLSessionWebSocketTask) async {
        lock.lock()
        let contacts = presenceContacts
        let visible = presenceVisible
        lock.unlock()
        do {
            try await send(task, ContactsFrame(type: "contacts", userIds: contacts))
            try await send(task, PresenceStateFrame(type: "presenceState", visible: visible))
        } catch {
            logger.debug("Couldn't send presence state; it will be resent on reconnect")
        }
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
