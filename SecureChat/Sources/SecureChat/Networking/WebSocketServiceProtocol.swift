import Foundation

/// Real-time delivery channel. A real implementation would wrap
/// `URLSessionWebSocketTask` against `wss://.../ws`; `MockWebSocketService`
/// wraps the in-memory store's `AsyncStream` instead, so `MessagingService`
/// doesn't need to know which one it's talking to.
protocol WebSocketServiceProtocol {
    func events(for userId: String) -> AsyncStream<EnvelopeDTO>
    func disconnect(userId: String)
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
}
