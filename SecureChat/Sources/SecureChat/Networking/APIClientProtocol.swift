import Foundation

/// Abstraction over the backend REST API. `MockAPIClient` implements this
/// against an in-memory store so the whole app runs without a real server.
protocol APIClientProtocol {
    /// FIX (Bug #1): registration uploads the whole one-time prekey pool.
    func register(username: String, bundle: PreKeyBundleUpload) async throws -> AuthToken
    func login(username: String) async throws -> AuthToken

    /// FIX (Bug #1): tops the server-side pool back up when it runs low.
    func replenishOneTimePreKeys(userId: String, keys: [OneTimePreKeyPublic]) async throws

    /// FIX (Bug #7): publishes a rotated signed prekey.
    ///
    /// Without this the rotation in `CryptoService` would be purely local — the
    /// server would keep handing out the original signed prekey forever and no
    /// initiator would ever handshake against the new one.
    func publishSignedPreKey(_ upload: SignedPreKeyUpload) async throws

    /// FIX (Bug #1): each call pops one prekey from the pool server-side.
    func fetchPreKeyBundle(forUsername username: String) async throws -> PreKeyBundle
    func fetchPreKeyBundle(forUserId userId: String) async throws -> PreKeyBundle

    func sendMessage(_ envelope: EnvelopeDTO) async throws
    func fetchEnvelopes(conversationId: String) async throws -> [EnvelopeDTO]
    func uploadMedia(data: Data) async throws -> MediaUploadResult
    func downloadMedia(mediaId: String) async throws -> Data
}

enum APIError: LocalizedError {
    case usernameTaken
    case userNotFound
    case mediaNotFound
    case notAuthenticated

    /// FIX (Bug #9): these now surface in the UI, so they need readable text.
    var errorDescription: String? {
        switch self {
        case .usernameTaken: return "That username is already taken."
        case .userNotFound: return "No such user."
        case .mediaNotFound: return "That attachment is no longer available."
        case .notAuthenticated: return "You're not signed in."
        }
    }
}
