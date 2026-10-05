import Foundation

/// Real-time delivery channel.
protocol WebSocketServiceProtocol {
    func events(for userId: String) -> AsyncStream<EnvelopeDTO>
    func disconnect(userId: String)

    /// Presence updates pushed by the server over the same socket.
    func presenceFrames() -> AsyncStream<PresenceFrame>

    /// Tells the server who our accepted contacts are and whether we're visible.
    func updatePresence(contacts: [String], isVisible: Bool)

    /// NEW: called after the socket *re*-connects (not on the first connect).
    ///
    /// While the connection was down the server queued anything sent to us,
    /// but only a backfill fetches it — so without this, messages sent during
    /// a dropped connection only arrived after the next app launch.
    func setReconnectHandler(_ handler: @escaping @Sendable () -> Void)
}

final class MockWebSocketService: WebSocketServiceProtocol {
    private let store: MockBackendStore

    init(store: MockBackendStore) {
        self.store = store
    }

    func events(for userId: String) -> AsyncStream<EnvelopeDTO> {
        AsyncStream { continuation in
            Task {
                for await envelope in await store.subscribe(userId: userId) {
                    continuation.yield(envelope)
                }
                continuation.finish()
            }
        }
    }

    func disconnect(userId: String) {
        Task { await store.unsubscribe(userId: userId) }
    }

    func presenceFrames() -> AsyncStream<PresenceFrame> {
        AsyncStream { $0.finish() }
    }

    func updatePresence(contacts: [String], isVisible: Bool) {}

    func setReconnectHandler(_ handler: @escaping @Sendable () -> Void) {}
}
