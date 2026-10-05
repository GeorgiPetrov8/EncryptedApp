import Foundation

/// A single-use nonce from the server. Signing it with the identity key
/// proves the request comes from the device that holds the account's keys.
struct LoginChallenge: Codable, Equatable {
    let nonce: String
    /// Which account the challenge is for — lets a device with several
    /// accounts pick the right keys before signing.
    let userId: String
    let expiresAt: Date
}

/// Signs a challenge. Main-actor isolated because it reads `CryptoService`.
typealias ChallengeSigner = @MainActor (LoginChallenge) throws -> Data

/// Abstraction over the backend REST API. `MockAPIClient` implements this
/// against an in-memory store so the whole app runs without a real server.
protocol APIClientProtocol {
    func register(username: String, bundle: PreKeyBundleUpload) async throws -> AuthToken

    /// Legacy username-only login. Kept for `MockAPIClient`; the real server
    /// refuses it — use `login(username:prove:)`.
    func login(username: String) async throws -> AuthToken

    /// FIX: challenge–response login. The real server requires a signature
    /// from the identity key; `RealAPIClient` used to send only the username,
    /// which the server answers with 400 — so signing in on a device (and
    /// restoring from a backup, which signs in afterwards) always failed.
    func login(username: String, prove: ChallengeSigner) async throws -> AuthToken

    func replenishOneTimePreKeys(userId: String, keys: [OneTimePreKeyPublic]) async throws
    func publishSignedPreKey(_ upload: SignedPreKeyUpload) async throws

    /// Read-only lookup that does **not** consume a one-time prekey.
    func fetchDirectoryEntry(userId: String) async throws -> DirectoryEntry
    func fetchDirectoryEntry(username: String) async throws -> DirectoryEntry

    /// Consumes a one-time prekey server-side. Only call when establishing a session.
    func fetchPreKeyBundle(forUsername username: String) async throws -> PreKeyBundle
    func fetchPreKeyBundle(forUserId userId: String) async throws -> PreKeyBundle

    func sendMessage(_ envelope: EnvelopeDTO) async throws
    func fetchEnvelopes(conversationId: String) async throws -> [EnvelopeDTO]
    func fetchPendingEnvelopes(userId: String, since cursor: Int) async throws -> PendingEnvelopesPage
    func acknowledge(userId: String, envelopeIds: [String]) async throws

    func uploadMedia(data: Data) async throws -> MediaUploadResult
    func downloadMedia(mediaId: String) async throws -> Data

    /// NEW: deletes the account on the server. Signed with the identity key,
    /// so a stolen session token alone can't destroy an account.
    func deleteAccountOnServer(prove: ChallengeSigner) async throws

    /// NEW: push notifications. `bearer` on removal is explicit because it
    /// runs during logout, while the stored token is being cleared.
    func registerPushToken(_ token: String, environment: String) async throws
    func removePushToken(_ token: String, bearer: String) async throws
}

/// Defaults so `MockAPIClient` keeps compiling without changes.
extension APIClientProtocol {
    func login(username: String, prove: ChallengeSigner) async throws -> AuthToken {
        try await login(username: username)
    }

    func deleteAccountOnServer(prove: ChallengeSigner) async throws {}
    func registerPushToken(_ token: String, environment: String) async throws {}
    func removePushToken(_ token: String, bearer: String) async throws {}
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
