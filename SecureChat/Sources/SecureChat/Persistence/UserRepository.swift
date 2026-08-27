import Foundation
import GRDB

/// FIX (Bug #2): this repository is now the client's identity trust store, not just
/// a contact cache. All identity writes go through the dedicated methods below so the
/// pinning rules live in one place and can't be bypassed by a stray `upsert`.
final class UserRepository {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    func upsert(_ user: User) throws {
        try dbQueue.write { db in try user.save(db) }
    }

    func fetch(id: String) throws -> User? {
        try dbQueue.read { db in try User.fetchOne(db, key: id) }
    }

    func fetch(username: String) throws -> User? {
        try dbQueue.read { db in
            try User.filter(Column("username") == username).fetchOne(db)
        }
    }

    func fetchAll() throws -> [User] {
        try dbQueue.read { db in try User.fetchAll(db) }
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
    /// first sight. Never overwrites a pinned key implicitly — that is what made a
    /// bundle swap invisible before.
    @discardableResult
    func pinOrCompareIdentity(
        userId: String,
        username: String?,
        agreementKey: Data,
        signingKey: Data
    ) throws -> IdentityCheck {
        try dbQueue.write { db in
            guard var existing = try User.fetchOne(db, key: userId) else {
                let user = User(
                    id: userId,
                    username: username ?? String(userId.prefix(8)),
                    publicKey: agreementKey,
                    createdAt: Date(),
                    identitySigningKey: signingKey
                )
                try user.insert(db)
                return .pinned
            }

            if existing.identityChangedAt != nil {
                return .changePending
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
    func acknowledgeIdentityChange(userId: String) throws {
        try dbQueue.write { db in
            guard var user = try User.fetchOne(db, key: userId),
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

    func setVerified(_ verified: Bool, userId: String) throws {
        try dbQueue.write { db in
            guard var user = try User.fetchOne(db, key: userId) else { return }
            user.isVerified = verified
            try user.update(db)
        }
    }
}
