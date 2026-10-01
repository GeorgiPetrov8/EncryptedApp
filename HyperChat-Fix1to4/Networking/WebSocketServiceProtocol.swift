import Foundation

/// Real-time delivery channel.
///
/// FIX (online status): `presenceFrames()` and `updatePresence(...)` are now
/// **protocol requirements**.
///
/// They used to live only in a protocol *extension* (in `PresenceService.swift`).
/// Extension-only methods are statically dispatched: calling them through a
/// `WebSocketServiceProtocol` value always ran the extension's no-op, even if
/// `RealWebSocketService` had its own implementation. Presence could never
/// have worked through that path.
protocol WebSocketServiceProtocol {
    func events(for userId: String) -> AsyncStream<EnvelopeDTO>
    func disconnect(userId: String)

    /// Presence updates pushed by the server over the same socket.
    func presenceFrames() -> AsyncStream<PresenceFrame>

    /// Tells the server who our accepted contacts are and whether we're visible
    /// (app in the foreground AND "show when I'm online" enabled). Remembered
    /// and re-sent after every reconnect.
    func updatePresence(contacts: [String], isVisible: Bool)
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

    /// The mock backend has no presence concept.
    func presenceFrames() -> AsyncStream<PresenceFrame> {
        AsyncStream { $0.finish() }
    }

    func updatePresence(contacts: [String], isVisible: Bool) {}
}
