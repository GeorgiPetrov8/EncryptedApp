import Foundation
import os

/// Real-time delivery over `URLSessionWebSocketTask`.
///
/// Authentication happens as the **first message** after the socket opens —
/// `{"type":"auth","token":"..."}` — rather than a `?token=` query parameter,
/// which would end up in every intermediary's access log.
///
/// FIX (online status):
///   - frames are dispatched by `type`: `envelope` goes to the message stream,
///     `presence` to the presence stream. Previously every non-envelope frame
///     was logged and dropped.
///   - after each successful auth the remembered contact list and visibility
///     are (re)sent, so presence survives reconnects.
final class RealWebSocketService: WebSocketServiceProtocol {
    private let webSocketURL: URL
    private let session: URLSession
    private let tokenStore: SessionTokenStore
    private let logger = Logger(subsystem: "com.HyperChat", category: "websocket")

    /// Per-account cancellation flags, so `disconnect(userId:)` stops the
    /// reconnect loop rather than just closing the current socket.
    private var cancelled: [String: Bool] = [:]
    private let lock = NSLock()

    // Presence state — all guarded by `lock`.
    private var presenceContinuation: AsyncStream<PresenceFrame>.Continuation?
    private var presenceGeneration = 0
    private var currentTask: URLSessionWebSocketTask?
    private var presenceContacts: [String] = []
    private var presenceVisible = true

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
                // Only clear if a newer stream hasn't replaced this one.
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

        // If not connected, the state is sent right after the next auth.
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

    /// Connects, authenticates, relays frames until the connection drops, then
    /// reconnects with exponential backoff (capped at 30s).
    private func runReconnectLoop(userId: String, continuation: AsyncStream<EnvelopeDTO>.Continuation) async {
        var backoff: UInt64 = 1
        while !isCancelled(userId) && !Task.isCancelled {
            do {
                try await runOneConnection(userId: userId, continuation: continuation)
                backoff = 1
            } catch {
                logger.error("WebSocket connection ended: \(String(describing: error), privacy: .public)")
            }
            guard !isCancelled(userId) && !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 30)
        }
        continuation.finish()
    }

    private func runOneConnection(
        userId: String,
        continuation: AsyncStream<EnvelopeDTO>.Continuation
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

        // The server replies to the contacts frame with a presence snapshot.
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
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
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
