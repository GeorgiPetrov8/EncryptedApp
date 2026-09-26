import Foundation
import os

/// Real-time delivery over `URLSessionWebSocketTask`, talking to the
/// hand-rolled WebSocket relay in `HyperChatServer/src/ws.js`.
///
/// Authentication happens as the **first message** after the socket opens —
/// `{"type":"auth","token":"..."}` — rather than a `?token=` query
/// parameter. A token in the URL ends up in every intermediary's access log
/// by default (reverse proxies, CDNs, the OS's own connection logging);
/// a token sent as a WS data frame over an already-TLS-protected connection
/// does not. The server closes the socket with code 4001 if this isn't the
/// first thing it receives, or if the token doesn't resolve to a session —
/// see `server.js`'s `upgrade` handler for the other half of this handshake.
final class RealWebSocketService: WebSocketServiceProtocol {
    private let webSocketURL: URL
    private let session: URLSession
    private let tokenStore: SessionTokenStore
    private let logger = Logger(subsystem: "com.HyperChat", category: "websocket")

    /// Per-account cancellation flags, so `disconnect(userId:)` stops the
    /// reconnect loop rather than just closing the current socket (which the
    /// loop would otherwise immediately reopen).
    private var cancelled: [String: Bool] = [:]
    private let lock = NSLock()

    init(
        webSocketURL: URL = NetworkConfiguration.webSocketURL,
        tokenStore: SessionTokenStore,
        session: URLSession = .shared
    ) {
        self.webSocketURL = webSocketURL
        self.tokenStore = tokenStore
        self.session = session
    }

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

    private func isCancelled(_ userId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled[userId] ?? false
    }

    private func setCancelled(_ value: Bool, for userId: String) {
        lock.lock(); defer { lock.unlock() }
        cancelled[userId] = value
    }

    /// Connects, authenticates, relays envelopes until the connection drops,
    /// then reconnects with exponential backoff (capped at 30s) — forever,
    /// until `disconnect(userId:)` is called or the `AsyncStream` consumer
    /// stops iterating.
    private func runReconnectLoop(userId: String, continuation: AsyncStream<EnvelopeDTO>.Continuation) async {
        var backoff: UInt64 = 1
        while !isCancelled(userId) && !Task.isCancelled {
            do {
                try await runOneConnection(userId: userId, continuation: continuation)
                backoff = 1 // a clean, authenticated session resets backoff
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
        defer { task.cancel(with: .goingAway, reason: nil) }

        try await send(task, AuthFrame(type: "auth", token: token))
        try await expectAuthOk(task)

        try await receiveLoop(task, userId: userId, continuation: continuation)
    }

    private func expectAuthOk(_ task: URLSessionWebSocketTask) async throws {
        let message = try await task.receive()
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let ack = try? HyperChatJSON.decoder.decode(AuthAck.self, from: data),
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

            guard let envelope = decodeEnvelopePush(data) else {
                logger.debug("Ignoring non-envelope WebSocket frame")
                continue
            }
            continuation.yield(envelope)
        }
    }

    private func decodeEnvelopePush(_ data: Data) -> EnvelopeDTO? {
        guard let push = try? HyperChatJSON.decoder.decode(EnvelopePush.self, from: data),
              push.type == "envelope" else { return nil }
        return push.envelope
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

private struct AuthAck: Decodable {
    let type: String
}

private struct EnvelopePush: Decodable {
    let type: String
    let envelope: EnvelopeDTO
}
