import Foundation

final class MockAPIClient: APIClientProtocol {
    private let store: MockBackendStore

    init(store: MockBackendStore) {
        self.store = store
    }

    /// A little artificial latency so loading states in the UI are visible
    /// and exercised, roughly like a real network call would.
    private func simulateLatency() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    func register(username: String, bundle: PreKeyBundleUpload) async throws -> AuthToken {
        await simulateLatency()
        return try await store.register(username: username, bundle: bundle)
    }

    func login(username: String) async throws -> AuthToken {
        await simulateLatency()
        return try await store.login(username: username)
    }

    /// FIX (Bug #1)
    func replenishOneTimePreKeys(userId: String, keys: [OneTimePreKeyPublic]) async throws {
        await simulateLatency()
        try await store.replenishOneTimePreKeys(userId: userId, keys: keys)
    }

    /// FIX (Bug #7)
    func publishSignedPreKey(_ upload: SignedPreKeyUpload) async throws {
        await simulateLatency()
        try await store.publishSignedPreKey(upload)
    }

    func fetchPreKeyBundle(forUsername username: String) async throws -> PreKeyBundle {
        await simulateLatency()
        return try await store.bundle(forUsername: username)
    }

    func fetchPreKeyBundle(forUserId userId: String) async throws -> PreKeyBundle {
        await simulateLatency()
        return try await store.bundle(forUserId: userId)
    }

    func sendMessage(_ envelope: EnvelopeDTO) async throws {
        await simulateLatency()
        await store.send(envelope)
    }

    func fetchEnvelopes(conversationId: String) async throws -> [EnvelopeDTO] {
        await simulateLatency()
        return await store.envelopes(conversationId: conversationId)
    }

    func uploadMedia(data: Data) async throws -> MediaUploadResult {
        await simulateLatency()
        let id = UUID().uuidString
        await store.storeMedia(id: id, data: data)
        return MediaUploadResult(mediaId: id)
    }

    func downloadMedia(mediaId: String) async throws -> Data {
        await simulateLatency()
        return try await store.media(id: mediaId)
    }
}
