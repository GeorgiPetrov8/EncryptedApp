import Foundation

/// A non-destructive directory record.
///
/// FIX: introduced so display-name lookups stop consuming key material.
///
/// `MessagingService.ensureContact` fell back to `fetchPreKeyBundle(forUserId:)` when
/// it had a user id but no name. That endpoint pops a one-time prekey from the peer's
/// pool on every call (`StoredBundle.issue()`), so a question as trivial as "what is
/// this contact called?" burned a prekey reserved for an X3DH handshake — and with the
/// pool drained, later handshakes silently fall back to the weaker no-dh4 path.
///
/// The identity keys are included because they're already public and it lets the
/// caller pin through the normal path without a second round trip. No one-time prekey
/// is ever returned here.
struct DirectoryEntry: Codable, Equatable {
    let userId: String
    let username: String
    let identityAgreementKey: Data
    let identitySigningKey: Data
}

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

    /// FIX: read-only lookup that does **not** consume a one-time prekey.
    /// Use this whenever you only need to identify a user, never `fetchPreKeyBundle`.
    func fetchDirectoryEntry(userId: String) async throws -> DirectoryEntry
    func fetchDirectoryEntry(username: String) async throws -> DirectoryEntry

    /// Consumes a one-time prekey server-side (Bug #1). Only call when actually
    /// establishing a session.
    func fetchPreKeyBundle(forUsername username: String) async throws -> PreKeyBundle
    func fetchPreKeyBundle(forUserId userId: String) async throws -> PreKeyBundle

    func sendMessage(_ envelope: EnvelopeDTO) async throws
    func fetchEnvelopes(conversationId: String) async throws -> [EnvelopeDTO]

    /// Everything addressed to this user since `cursor` (Bug #12).
    func fetchPendingEnvelopes(userId: String, since cursor: Int) async throws -> PendingEnvelopesPage

    /// Lets the server drop envelopes we've durably stored (Bug #12).
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
