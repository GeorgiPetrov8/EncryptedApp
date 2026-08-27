import Foundation
import GRDB

/// A known user (self or a contact), as seen by **one** local account.
///
/// FIX: `ownerUserId` added, and the primary key is now `(ownerUserId, id)`.
///
/// Pinning is a per-account trust decision. Alice deciding she trusts Bob's identity
/// key says nothing about whether a second account on the same device should. Sharing
/// one global `users` table conflated those, and the old `UNIQUE(username)` meant two
/// accounts could not even hold contacts of the same name.
///
/// This also makes account deletion expressible: previously there was no way to say
/// "remove the contacts *this* account pinned", so `AccountDeletionService` left them
/// behind forever.
struct User: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "users"

    /// Which local account's view of this person this row represents.
    var ownerUserId: String
    var id: String
    var username: String
    /// Pinned identity agreement key (X25519).
    ///
    /// May be empty for a contact placeholder — a row created just to give a peer a
    /// display name before any key exchange (Bug #11). Only `pinOrCompareIdentity`
    /// may populate it.
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
        ownerUserId: String,
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
        self.ownerUserId = ownerUserId
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

    /// A placeholder has a name but no pinned key yet (Bug #11).
    var isPlaceholderContact: Bool { publicKey.isEmpty }
}
