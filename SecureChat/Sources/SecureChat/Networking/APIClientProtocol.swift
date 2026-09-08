import Foundation

/// Abstraction over the backend REST API. `MockAPIClient` implements this
/// against an in-memory store so the whole app runs without a real server.
protocol APIClientProtocol {
    /// Registration uploads the whole one-time prekey pool (Bug #1).
    func register(username: String, bundle: PreKeyBundleUpload) async throws -> AuthToken
    func login(username: String) async throws -> AuthToken

    /// Tops the server-side pool back up when it runs low (Bug #1).
    func replenishOneTimePreKeys(userId: String, keys: [OneTimePreKeyPublic]) async throws

    /// Publishes a rotated signed prekey (Bug #7).
    func publishSignedPreKey(_ upload: SignedPreKeyUpload) async throws

    /// Each call pops one prekey from the pool server-side (Bug #1).
    func fetchPreKeyBundle(forUsername username: String) async throws -> PreKeyBundle
    func fetchPreKeyBundle(forUserId userId: String) async throws -> PreKeyBundle

    func sendMessage(_ envelope: EnvelopeDTO) async throws
    func fetchEnvelopes(conversationId: String) async throws -> [EnvelopeDTO]

    /// FIX (Bug #12): everything addressed to this user since `cursor`.
    ///
    /// The old code only ever received through the live `AsyncStream`. If nobody was
    /// listening, `MockBackendStore.send` yielded into the void — the envelope was
    /// filed under `envelopesByConversation` but the recipient never learned of it.
    /// `fetchEnvelopes(conversationId:)` existed but was never called, and it needs a
    /// conversation id the recipient doesn't have yet for a brand-new chat.
    func fetchPendingEnvelopes(userId: String, since cursor: Int) async throws -> PendingEnvelopesPage

    /// FIX (Bug #12): lets the server drop envelopes we've durably stored.
    func acknowledge(userId: String, envelopeIds: [String]) async throws

    func uploadMedia(data: Data) async throws -> MediaUploadResult
    func downloadMedia(mediaId: String) async throws -> Data
}

enum APIError: LocalizedError {
    case usernameTaken
    case userNotFound
    case mediaNotFound
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .usernameTaken: return "That username is already taken."
        case .userNotFound: return "No such user."
        case .mediaNotFound: return "That attachment is no longer available."
        case .notAuthenticated: return "You're not signed in."
        }
    }
}
