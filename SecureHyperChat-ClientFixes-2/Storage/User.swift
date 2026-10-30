import Foundation
import GRDB

/// A known user (self or a contact), as seen by **one** local account.
///
/// Primary key is `(ownerUserId, id)`: pinning is a per-account trust decision.
struct User: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "users"

    var ownerUserId: String
    var id: String
    /// FIX (S1): only ever set from the server directory (or our own account),
    /// never from anything the other person sends.
    var username: String
    /// Pinned identity agreement key (X25519). Empty for a placeholder.
    var publicKey: Data
    var createdAt: Date
    var identitySigningKey: Data?
    var isVerified: Bool
    var identityChangedAt: Date?
    var pendingIdentityAgreementKey: Data?
    var pendingIdentitySigningKey: Data?

    // MARK: Profile (migration v9)

    /// The name the contact chose for themselves. **Unverified** — they can type
    /// anything, including someone else's name. Shown only as a secondary line.
    var displayName: String?
    var avatarFileName: String?
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

    var hasUnacknowledgedIdentityChange: Bool { identityChangedAt != nil }

    var isPlaceholderContact: Bool { publicKey.isEmpty }

    /// The id prefix used before the real username is known.
    var hasPlaceholderUsername: Bool { username.isEmpty || username == String(id.prefix(8)) }

    /// FIX (S1): what to show for this person is the **username**, which the
    /// server guarantees is unique. It used to be `displayName` — text the
    /// contact controls — so anyone could appear as "Mum" or "Bank Support".
    var shownName: String {
        username.isEmpty ? String(id.prefix(8)) : username
    }

    /// The self-chosen name, cleaned, and only when it adds something.
    var unverifiedDisplayName: String? {
        guard let clean = SafeText.displayName(displayName),
              clean.caseInsensitiveCompare(username) != .orderedSame else { return nil }
        return clean
    }
}
