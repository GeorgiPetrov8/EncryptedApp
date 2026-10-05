import Foundation
import os

/// Real-time delivery over `URLSessionWebSocketTask`.
///
/// Authentication is the first message after the socket opens, not a URL
/// query parameter (which would end up in proxy access logs).
final class RealWebSocketService: WebSocketServiceProtocol {
    private let webSocketURL: URL
    private let session: URLSession
    private let tokenStore: SessionTokenStore
    private let logger = Logger(subsystem: "com.HyperChat", category: "websocket")

    /// All guarded by `lock`.
    private let lock = NSLock()
    private var cancelled: [String: Bool] = [:]
    private var presenceContinuation: AsyncStream<PresenceFrame>.Continuation?
    private var presenceGeneration = 0
    private var currentTask: URLSessionWebSocketTask?
    private var presenceContacts: [String] = []
    private var presenceVisible = true
    private var reconnectHandler: (@Sendable () -> Void)?

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
        // Closing the socket ends the pending `receive()` right away, instead
        // of the loop noticing the flag only when the next frame arrives.
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

    private func runReconnectLoop(userId: String, continuation: AsyncStream<EnvelopeDTO>.Continuation) async {
        var backoff: UInt64 = 1
        var connectionCount = 0
        while !isCancelled(userId) && !Task.isCancelled {
            do {
                try await runOneConnection(userId: userId, continuation: continuation) {
                    // Runs right after authentication succeeds.
                    connectionCount += 1
                    backoff = 1
                    if connectionCount > 1 { self.notifyReconnected() }
                }
            } catch {
                logger.error("WebSocket connection ended: \(String(describing: error), privacy: .public)")
            }
            guard !isCancelled(userId) && !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 30)
        }
        continuation.finish()
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
            throw NetworkError.missingSessionToken
        }

        let task = session.webSocketTask(with: webSocketURL)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            lock.lock()
            if currentTask === task { currentTask = nil }
            lock.unlock()
        }

        try await send(task, AuthFrame(type: "auth", token: token))
        try await expectAuthOk(task)

        lock.lock()
        currentTask = task
        lock.unlock()

        onAuthenticated()
        await sendPresenceState(on: task)
        try await receiveLoop(task, userId: userId, continuation: continuation)
    }

    private func expectAuthOk(_ task: URLSessionWebSocketTask) async throws {
        let message = try await task.receive()
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let ack = try? HyperChatJSON.decoder.decode(TypedFrame.self, from: data),
              ack.type == "authOk"
        else {
            throw NetworkError.server(status: 0, code: "wsAuthFailed", message: "WebSocket authentication was rejected")
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
            guard let frame = try? HyperChatJSON.decoder.decode(TypedFrame.self, from: data) else { continue }

            switch frame.type {
            case "envelope":
                if let push = try? HyperChatJSON.decoder.decode(EnvelopePush.self, from: data) {
                    continuation.yield(push.envelope)
                }
            case "presence":
                if let presence = try? HyperChatJSON.decoder.decode(PresenceFrame.self, from: data) {
                    lock.lock()
                    let presenceContinuation = self.presenceContinuation
                    lock.unlock()
                    presenceContinuation?.yield(presence)
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
        let data = try HyperChatJSON.encoder.encode(value)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
}

private struct AuthFrame: Encodable {
    let type: String
    let token: String
}

private struct ContactsFrame: Encodable {
    let type: String
    let userIds: [String]
}

private struct PresenceStateFrame: Encodable {
    let type: String
    let visible: Bool
}

private struct TypedFrame: Decodable {
    let type: String
}

private struct EnvelopePush: Decodable {
    let type: String
    let envelope: EnvelopeDTO
}
