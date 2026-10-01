import Foundation
import GRDB

/// A known user (self or a contact), as seen by **one** local account.
///
/// Primary key is `(ownerUserId, id)`: pinning is a per-account trust decision,
/// so two local accounts never share a contact row.
struct User: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "users"

    /// Which local account's view of this person this row represents.
    var ownerUserId: String
    var id: String
    var username: String
    /// Pinned identity agreement key (X25519). Empty for a contact placeholder
    /// (Bug #11) — only `pinOrCompareIdentity` may populate it.
    var publicKey: Data
    var createdAt: Date
    /// Pinned identity signing key (Ed25519).
    var identitySigningKey: Data?
    /// Set once the user has compared safety numbers out of band and confirmed.
    var isVerified: Bool
    /// Non-nil when the server presented an identity that differs from the pinned one.
    var identityChangedAt: Date?
    var pendingIdentityAgreementKey: Data?
    var pendingIdentitySigningKey: Data?

    // MARK: Profile (migration v9)
    //
    // FIX: the v9 migration added these columns, but this struct never
    // declared them — GRDB silently ignores undeclared columns, so nothing
    // could read or write a profile.

    /// Name the contact chose for themselves, pushed via `ProfilePayload`.
    var displayName: String?
    /// File name (not path) inside the avatars directory — see `ProfileService`.
    var avatarFileName: String?
    /// `ProfilePayload.updatedAt` of the last profile applied; older pushes
    /// arriving out of order are ignored.
    var profileUpdatedAt: Date?

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
        pendingIdentitySigningKey: Data? = nil,
        displayName: String? = nil,
        avatarFileName: String? = nil,
        profileUpdatedAt: Date? = nil
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
        self.displayName = displayName
        self.avatarFileName = avatarFileName
        self.profileUpdatedAt = profileUpdatedAt
    }

    /// True when the server has offered keys we haven't accepted.
    var hasUnacknowledgedIdentityChange: Bool {
        identityChangedAt != nil
    }

    /// A placeholder has a name but no pinned key yet (Bug #11).
    var isPlaceholderContact: Bool { publicKey.isEmpty }

    /// What to show for this person: their chosen name, else the username.
    var shownName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return username.isEmpty ? String(id.prefix(8)) : username
    }
}
