import Foundation
import GRDB

/// The client's identity trust store (Bug #2) and contact cache (Bug #11).
///
/// FIX: every method is now scoped to an owning account. With `users` keyed by
/// `(ownerUserId, id)`, an unscoped lookup would be ambiguous and an unscoped write
/// would silently clobber another account's pinned keys.
final class UserRepository {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    private static func key(ownerUserId: String, id: String) -> [String: DatabaseValueConvertible] {
        ["ownerUserId": ownerUserId, "id": id]
    }

    func upsert(_ user: User) throws {
        try dbQueue.write { db in try user.save(db) }
    }

    func fetch(ownerUserId: String, id: String) throws -> User? {
        try dbQueue.read { db in
            try User.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: id))
        }
    }

    func fetch(ownerUserId: String, username: String) throws -> User? {
        try dbQueue.read { db in
            try User
                .filter(Column("ownerUserId") == ownerUserId)
                .filter(Column("username") == username)
                .fetchOne(db)
        }
    }

    func fetchAll(ownerUserId: String) throws -> [User] {
        try dbQueue.read { db in
            try User.filter(Column("ownerUserId") == ownerUserId).fetchAll(db)
        }
    }

    /// FIX: the missing half of account deletion.
    ///
    /// `AccountDeletionService` removed messages, conversations, sessions, media and
    /// Keychain material, but never the `users` rows — so pinned identity keys and
    /// usernames of a deleted account survived in the shared table indefinitely. With
    /// `ownerUserId` in place this is finally expressible.
    func deleteAll(ownerUserId: String) throws {
        try dbQueue.write { db in
            _ = try User.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
        }
    }

    // MARK: Contact caching (Bug #11)

    /// Records a display name for a peer we haven't pinned yet.
    ///
    /// Deliberately separate from `pinOrCompareIdentity`: knowing what to *call*
    /// someone is not the same as trusting their keys.
    func upsertContactPlaceholder(ownerUserId: String, userId: String, username: String) throws {
        try dbQueue.write { db in
            if var existing = try User.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: userId)) {
                guard existing.username != username else { return }
                existing.username = username
                try existing.update(db)
            } else {
                try User(
                    ownerUserId: ownerUserId,
                    id: userId,
                    username: username,
                    publicKey: Data(),
                    createdAt: Date()
                ).insert(db)
            }
        }
    }

    /// Refreshes only the display name, never touching key material.
    func updateUsername(ownerUserId: String, userId: String, username: String) throws {
        try dbQueue.write { db in
            guard var user = try User.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: userId)),
                  user.username != username else { return }
            user.username = username
            try user.update(db)
        }
    }

    // MARK: Identity pinning (Bug #2)

    enum IdentityCheck: Equatable {
        /// No prior record — the identity has just been pinned (trust on first use).
        case pinned
        /// Presented identity matches what we pinned.
        case matches
        /// Presented identity differs. Recorded as pending; the caller must abort.
        case changed
        /// A previously recorded change is still unacknowledged.
        case changePending
    }

    /// Compares a server-presented identity against the pinned one, pinning it on
    /// first sight. Never overwrites a pinned key implicitly.
    @discardableResult
    func pinOrCompareIdentity(
        ownerUserId: String,
        userId: String,
        username: String?,
        agreementKey: Data,
        signingKey: Data
    ) throws -> IdentityCheck {
        try dbQueue.write { db in
            guard var existing = try User.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: userId)) else {
                try User(
                    ownerUserId: ownerUserId,
                    id: userId,
                    username: username ?? String(userId.prefix(8)),
                    publicKey: agreementKey,
                    createdAt: Date(),
                    identitySigningKey: signingKey
                ).insert(db)
                return .pinned
            }

            if existing.identityChangedAt != nil {
                return .changePending
            }

            // A placeholder row (Bug #11) has no pinned key yet, so this is still a
            // first pin rather than a mismatch.
            if existing.publicKey.isEmpty {
                existing.publicKey = agreementKey
                existing.identitySigningKey = signingKey
                if let username { existing.username = username }
                try existing.update(db)
                return .pinned
            }

            let signingMatches = existing.identitySigningKey == nil || existing.identitySigningKey == signingKey
            if existing.publicKey == agreementKey && signingMatches {
                var didChange = false
                if existing.identitySigningKey == nil {
                    existing.identitySigningKey = signingKey // backfill for v1 rows
                    didChange = true
                }
                if let username, existing.username != username {
                    existing.username = username
                    didChange = true
                }
                if didChange { try existing.update(db) }
                return .matches
            }

            existing.identityChangedAt = Date()
            existing.isVerified = false
            existing.pendingIdentityAgreementKey = agreementKey
            existing.pendingIdentitySigningKey = signingKey
            try existing.update(db)
            return .changed
        }
    }

    /// Promotes the pending identity to the pinned one. Only ever called from an
    /// explicit user action in `VerifyIdentityView`.
    func acknowledgeIdentityChange(ownerUserId: String, userId: String) throws {
        try dbQueue.write { db in
            guard var user = try User.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: userId)),
                  let newAgreement = user.pendingIdentityAgreementKey else { return }
            user.publicKey = newAgreement
            user.identitySigningKey = user.pendingIdentitySigningKey
            user.pendingIdentityAgreementKey = nil
            user.pendingIdentitySigningKey = nil
            user.identityChangedAt = nil
            user.isVerified = false // a new identity always starts unverified
            try user.update(db)
        }
    }

    func setVerified(_ verified: Bool, ownerUserId: String, userId: String) throws {
        try dbQueue.write { db in
            guard var user = try User.fetchOne(db, key: Self.key(ownerUserId: ownerUserId, id: userId)) else { return }
            user.isVerified = verified
            try user.update(db)
        }
    }
}
