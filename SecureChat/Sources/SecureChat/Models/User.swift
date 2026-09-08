import Foundation
import GRDB

/// A known user (self or a contact). `publicKey` is the raw X25519 identity
/// agreement key — the *pinned* one, i.e. what we trust for this user.
///
/// FIX (Bug #2): this row is the client's trust store. On first handshake we pin the
/// peer's identity (trust-on-first-use); on every later handshake we compare. A
/// mismatch is never accepted silently — it is recorded in the `pending*` columns
/// and surfaced to the user, who must explicitly accept it.
struct User: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "users"

    var id: String
    var username: String
    /// Pinned identity agreement key (X25519).
    ///
    /// FIX (Bug #11): may be empty for a contact placeholder — a row created just to
    /// give a peer a display name before any key exchange has happened. Knowing what
    /// to call someone is not the same as trusting their keys, so the two are stored
    /// independently and only `pinOrCompareIdentity` may populate this.
    var publicKey: Data
    var createdAt: Date

    /// Pinned identity signing key (Ed25519). Optional only because rows written by
    /// schema v1 predate it.
    var identitySigningKey: Data?

    /// Set once the user has compared safety numbers out of band and confirmed.
    var isVerified: Bool

    /// Non-nil when the server presented an identity that differs from the pinned one.
    /// While this is set, `MessagingService` refuses to establish a new session.
    var identityChangedAt: Date?

    /// The unaccepted replacement keys, held so `VerifyIdentityView` can show the new
    /// safety number before the user decides.
    var pendingIdentityAgreementKey: Data?
    var pendingIdentitySigningKey: Data?

    init(
        id: String,
        username: String,
        publicKey: Data,
        createdAt: Date,
        identitySigningKey: Data? = nil,
        isVerified: Bool = false,
        identityChangedAt: Date? = nil,
        pendingIdentityAgreementKey: Data? = nil,
        pendingIdentitySigningKey: Data? = nil
    ) {
        self.id = id
        self.username = username
        self.publicKey = publicKey
        self.createdAt = createdAt
        self.identitySigningKey = identitySigningKey
        self.isVerified = isVerified
        self.identityChangedAt = identityChangedAt
        self.pendingIdentityAgreementKey = pendingIdentityAgreementKey
        self.pendingIdentitySigningKey = pendingIdentitySigningKey
    }

    /// True when the server has offered keys we haven't accepted — the UI must block
    /// on this rather than quietly starting a new session.
    var hasUnacknowledgedIdentityChange: Bool {
        identityChangedAt != nil
    }

    /// FIX (Bug #11): a placeholder has a name but no pinned key yet.
    var isPlaceholderContact: Bool { publicKey.isEmpty }
}
