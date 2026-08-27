import Foundation
import CryptoKit

/// Central point of contact for all cryptographic operations. Owns:
///  - the device's identity key + signed prekeys + one-time prekeys
///  - the device-local storage key (encrypts message history / session
///    state / thumbnails at rest — distinct from the Double Ratchet keys)
///  - in-memory active `DoubleRatchetSession`s, keyed by peer user id
///
/// FIX (Bug #10): the service is bound to exactly one account at a time via
/// `activate(userId:)`. Every Keychain item is namespaced by that userId, so a
/// second registration can no longer clobber the first account's storage key
/// or identity.
final class CryptoService {
    private let keychain = KeychainStore()
    private(set) var signedPreKey: SignedPreKey?
    private(set) var identity: IdentityKeyPair?
    private(set) var activeUserId: String?

    private var activeSessions: [String: DoubleRatchetSession] = [:]

    /// FIX (Bug #6/#10): cached in memory once unlocked. The item is
    /// `.userPresence`-protected, so reading it triggers a biometric prompt and must
    /// not happen per message; and `logout` needs a definite point at which the key
    /// leaves memory.
    private var cachedStorageKey: SymmetricKey?

    static let oneTimePreKeyBatchSize = 20

    private enum Keys {
        static let identity = "identityKeyPair"
        static let oneTimePreKeysPrefix = "otk_"
        static let oneTimePreKeyLiveIds = "otkLiveIds"
        static let oneTimePreKeyNextId = "otkNextId"
        static let storageKey = "localStorageKey"

        /// FIX (Bug #7): signed prekeys are versioned by id so a rotated-out key can
        /// be retained through its grace period. The old code used a single fixed
        /// `"signedPreKey"` account, which made it structurally impossible to hold
        /// the current and previous keys at the same time.
        static let signedPreKeyPrefix = "signedPreKey_"
        static let signedPreKeySignaturePrefix = "signedPreKeySig_"
        static let signedPreKeyCreatedAtPrefix = "signedPreKeyCreatedAt_"
        static let signedPreKeyLiveIds = "spkLiveIds"
        static let signedPreKeyCurrentId = "spkCurrentId"
    }

    // MARK: Account binding (Bug #10)

    func activate(userId: String) {
        if activeUserId != userId {
            deactivate()
        }
        activeUserId = userId
    }

    /// Drops all in-memory secrets. Does **not** delete anything from the Keychain —
    /// logging out must never destroy an account's history (see `deleteAccount`).
    func deactivate() {
        activeUserId = nil
        identity = nil
        signedPreKey = nil
        cachedStorageKey = nil
        activeSessions.removeAll()
    }

    private func account(_ key: String) throws -> String {
        guard let userId = activeUserId else { throw CryptoError.noActiveAccount }
        return KeychainStore.namespaced(key, userId: userId)
    }

    /// FIX (Bug #10): takes an explicit userId. The old global `hasIdentity` let
    /// `AuthService.login` accept "some identity exists" as proof that *this*
    /// account's identity existed, so logging in as B could load A's keys.
    func hasIdentity(forUserId userId: String) -> Bool {
        keychain.loadIfPresent(key: KeychainStore.namespaced(Keys.identity, userId: userId)) != nil
    }

    var hasIdentity: Bool {
        guard let userId = activeUserId else { return false }
        return hasIdentity(forUserId: userId)
    }

    // MARK: Identity lifecycle

    /// Call once at registration. Generates and persists all key material to the
    /// Keychain and returns the public bundle to upload.
    ///
    /// - Parameter username: FIX (Bug #11) — published alongside the keys so peers can
    ///   resolve a display name from a user id alone. Without it the inbound path,
    ///   which only ever sees a `senderId`, had no way to name the contact and every
    ///   conversation rendered as "Unknown".
    /// - Parameter force: FIX (Bug #10) — refuses to overwrite existing material
    ///   unless explicitly requested.
    @discardableResult
    func generateIdentityAndBundle(
        userId: String,
        username: String,
        oneTimePreKeyCount: Int = CryptoService.oneTimePreKeyBatchSize,
        force: Bool = false
    ) throws -> PreKeyBundleUpload {
        if hasIdentity(forUserId: userId) && !force {
            throw CryptoError.identityAlreadyExists
        }
        activate(userId: userId)

        let identity = IdentityKeyPair.generate()
        try keychain.save(key: try account(Keys.identity), data: identity.rawRepresentation())
        self.identity = identity

        // FIX (Bug #6): the storage key is gated on user presence (Face ID / Touch ID
        // / passcode) instead of a password that was derived and thrown away.
        let storageKey = AESGCM.randomKey()
        try keychain.save(
            key: try account(Keys.storageKey),
            data: storageKey.withUnsafeBytes { Data($0) },
            requireUserPresence: true
        )
        cachedStorageKey = storageKey

        try saveSignedPreKeyLiveIds([])
        let spk = try rotateSignedPreKey(force: true)

        try saveNextOneTimePreKeyId(0)
        try saveLiveOneTimePreKeyIds([])
        let oneTimePreKeys = try generateOneTimePreKeys(count: oneTimePreKeyCount)

        return PreKeyBundleUpload(
            userId: userId,
            username: username,
            identityAgreementKey: identity.agreementPublicKey.rawRepresentation,
            identitySigningKey: identity.signingPublicKey.rawRepresentation,
            signedPreKeyId: spk.id,
            signedPreKey: spk.publicKey.rawRepresentation,
            signedPreKeySignature: spk.signature,
            oneTimePreKeys: oneTimePreKeys
        )
    }

    /// Call on app launch / login, once we know keys already exist for this account.
    func loadIdentityFromKeychain(userId: String) throws {
        activate(userId: userId)
        let identityData = try keychain.load(key: try account(Keys.identity))
        identity = try IdentityKeyPair.from(rawRepresentation: identityData)
        signedPreKey = try loadCurrentSignedPreKey()
    }

    /// FIX (Bug #10): the only path that destroys data, and it is explicit.
    func deleteAccount(userId: String) {
        keychain.deleteAll(forUserId: userId)
        if activeUserId == userId { deactivate() }
    }

    // MARK: Signed prekey rotation (Bug #7)

    @discardableResult
    func rotateSignedPreKeyIfNeeded() throws -> SignedPreKey? {
        let current = try? loadCurrentSignedPreKey()
        guard let current else { return try rotateSignedPreKey(force: true) }
        guard current.needsRotation else {
            signedPreKey = current
            try pruneExpiredSignedPreKeys()
            return nil
        }
        return try rotateSignedPreKey(force: true)
    }

    /// Generates the next signed prekey, keeping the previous one on disk so
    /// in-flight handshakes against it still resolve during the grace period.
    @discardableResult
    func rotateSignedPreKey(force: Bool = false) throws -> SignedPreKey {
        guard let identity else { throw CryptoError.noActiveAccount }

        let nextId = (try? loadCurrentSignedPreKeyId()).map { $0 &+ 1 } ?? 1
        let spk = try SignedPreKey.generate(id: nextId, signedBy: identity)

        try keychain.save(key: try account(Keys.signedPreKeyPrefix + String(spk.id)), data: spk.privateKey.rawRepresentation)
        try keychain.save(key: try account(Keys.signedPreKeySignaturePrefix + String(spk.id)), data: spk.signature)
        try keychain.save(
            key: try account(Keys.signedPreKeyCreatedAtPrefix + String(spk.id)),
            data: Self.encode(spk.createdAt)
        )

        var liveIds = loadSignedPreKeyLiveIds()
        if !liveIds.contains(spk.id) { liveIds.append(spk.id) }
        try saveSignedPreKeyLiveIds(liveIds)
        try saveCurrentSignedPreKeyId(spk.id)

        signedPreKey = spk
        try pruneExpiredSignedPreKeys()
        return spk
    }

    /// Looks up a signed prekey by the id the initiator actually used.
    ///
    /// FIX (Bug #7): `MessagingService.handleIncoming` previously called
    /// `requireSignedPreKey()`, which returned whatever the *current* key happened
    /// to be and ignored `handshake.usedSignedPreKeyId` entirely.
    func signedPreKey(withId id: UInt32) throws -> SignedPreKey {
        guard let privateData = keychain.loadIfPresent(key: try account(Keys.signedPreKeyPrefix + String(id))),
              let signature = keychain.loadIfPresent(key: try account(Keys.signedPreKeySignaturePrefix + String(id))),
              let createdAtData = keychain.loadIfPresent(key: try account(Keys.signedPreKeyCreatedAtPrefix + String(id)))
        else {
            throw CryptoError.unknownPreKeyId
        }
        return SignedPreKey(
            id: id,
            privateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateData),
            signature: signature,
            createdAt: try Self.decodeDate(createdAtData)
        )
    }

    private func loadCurrentSignedPreKey() throws -> SignedPreKey {
        try signedPreKey(withId: try loadCurrentSignedPreKeyId())
    }

    /// Deletes superseded signed prekeys once past the grace period. The current key
    /// is never pruned regardless of age.
    private func pruneExpiredSignedPreKeys() throws {
        let currentId = try? loadCurrentSignedPreKeyId()
        var survivors: [UInt32] = []

        for id in loadSignedPreKeyLiveIds() {
            if id == currentId {
                survivors.append(id)
                continue
            }
            guard let spk = try? signedPreKey(withId: id) else { continue }
            if spk.age < SignedPreKey.rotationInterval + SignedPreKey.gracePeriod {
                survivors.append(id)
            } else {
                keychain.delete(key: try account(Keys.signedPreKeyPrefix + String(id)))
                keychain.delete(key: try account(Keys.signedPreKeySignaturePrefix + String(id)))
                keychain.delete(key: try account(Keys.signedPreKeyCreatedAtPrefix + String(id)))
            }
        }

        try saveSignedPreKeyLiveIds(survivors)
    }

    private func loadSignedPreKeyLiveIds() -> [UInt32] {
        guard let name = try? account(Keys.signedPreKeyLiveIds),
              let data = keychain.loadIfPresent(key: name),
              let ids = try? JSONDecoder().decode([UInt32].self, from: data) else { return [] }
        return ids
    }

    private func saveSignedPreKeyLiveIds(_ ids: [UInt32]) throws {
        try keychain.save(key: try account(Keys.signedPreKeyLiveIds), data: JSONEncoder().encode(ids))
    }

    private func loadCurrentSignedPreKeyId() throws -> UInt32 {
        guard let data = keychain.loadIfPresent(key: try account(Keys.signedPreKeyCurrentId)) else {
            throw CryptoError.unknownPreKeyId
        }
        return try Self.decodeUInt32(data)
    }

    private func saveCurrentSignedPreKeyId(_ id: UInt32) throws {
        try keychain.save(key: try account(Keys.signedPreKeyCurrentId), data: Self.encode(id))
    }

    // MARK: One-time prekeys (Bug #1)

    var remainingOneTimePreKeyCount: Int {
        loadLiveOneTimePreKeyIds().count
    }

    func generateOneTimePreKeys(count: Int) throws -> [OneTimePreKeyPublic] {
        guard count > 0 else { return [] }

        var nextId = loadNextOneTimePreKeyId()
        var liveIds = loadLiveOneTimePreKeyIds()
        var published: [OneTimePreKeyPublic] = []
        published.reserveCapacity(count)

        for _ in 0..<count {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let id = nextId
            nextId &+= 1

            try keychain.save(
                key: try account(Keys.oneTimePreKeysPrefix + String(id)),
                data: privateKey.rawRepresentation
            )
            liveIds.append(id)
            published.append(OneTimePreKeyPublic(id: id, publicKey: privateKey.publicKey.rawRepresentation))
        }

        try saveNextOneTimePreKeyId(nextId)
        try saveLiveOneTimePreKeyIds(liveIds)
        return published
    }

    func consumeOneTimePreKey(id: UInt32) throws -> Curve25519.KeyAgreement.PrivateKey? {
        let name = try account(Keys.oneTimePreKeysPrefix + String(id))
        guard let data = keychain.loadIfPresent(key: name) else { return nil }
        keychain.delete(key: name)
        try saveLiveOneTimePreKeyIds(loadLiveOneTimePreKeyIds().filter { $0 != id })
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    private func loadLiveOneTimePreKeyIds() -> [UInt32] {
        guard let name = try? account(Keys.oneTimePreKeyLiveIds),
              let data = keychain.loadIfPresent(key: name),
              let ids = try? JSONDecoder().decode([UInt32].self, from: data) else { return [] }
        return ids
    }

    private func saveLiveOneTimePreKeyIds(_ ids: [UInt32]) throws {
        try keychain.save(key: try account(Keys.oneTimePreKeyLiveIds), data: JSONEncoder().encode(ids))
    }

    private func loadNextOneTimePreKeyId() -> UInt32 {
        guard let name = try? account(Keys.oneTimePreKeyNextId),
              let data = keychain.loadIfPresent(key: name),
              let value = try? Self.decodeUInt32(data) else { return 0 }
        return value
    }

    private func saveNextOneTimePreKeyId(_ value: UInt32) throws {
        try keychain.save(key: try account(Keys.oneTimePreKeyNextId), data: Self.encode(value))
    }

    // MARK: Fixed-width encoding

    /// FIX (Bug #20): big-endian and explicitly sized.
    ///
    /// The original read the signed prekey id back with
    /// `spkIdData.withUnsafeBytes { $0.load(as: UInt32.self) }`. `Data` gives no
    /// alignment guarantee and `load(as:)` requires one, so that was undefined
    /// behaviour — and it was also host-endian, so the bytes weren't portable.
    /// `loadUnaligned` plus an explicit byte order fixes both.
    private static func encode(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func decodeUInt32(_ data: Data) throws -> UInt32 {
        guard data.count == 4 else { throw CryptoError.invalidKeyData }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
    }

    private static func encode(_ date: Date) -> Data {
        withUnsafeBytes(of: date.timeIntervalSince1970.bitPattern.bigEndian) { Data($0) }
    }

    private static func decodeDate(_ data: Data) throws -> Date {
        guard data.count == 8 else { throw CryptoError.invalidKeyData }
        let bits = data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian
        return Date(timeIntervalSince1970: Double(bitPattern: bits))
    }

    // MARK: Local storage (at-rest) encryption

    /// Cached after first unlock (Bugs #6, #10). The Keychain item is
    /// `.userPresence`-gated, so hitting it once per message — as the old
    /// `loadStorageKey()` did via `plaintext(for:)` in list rendering — would mean a
    /// biometric prompt per row.
    private func storageKey() throws -> SymmetricKey {
        if let cachedStorageKey { return cachedStorageKey }
        let data = try keychain.load(key: try account(Keys.storageKey))
        let key = SymmetricKey(data: data)
        cachedStorageKey = key
        return key
    }

    /// Forces the biometric prompt up front (at login) rather than at first render.
    func unlockStorageKey() throws {
        _ = try storageKey()
    }

    func encryptForStorage(_ plaintext: Data) throws -> Data {
        try AESGCM.seal(plaintext: plaintext, key: storageKey())
    }

    func decryptFromStorage(_ ciphertext: Data) throws -> Data {
        try AESGCM.open(ciphertext: ciphertext, key: storageKey())
    }

    // MARK: Session management

    func session(for peerUserId: String) -> DoubleRatchetSession? {
        activeSessions[peerUserId]
    }

    func setSession(_ session: DoubleRatchetSession, for peerUserId: String) {
        activeSessions[peerUserId] = session
    }

    func restoreSession(encryptedState: Data, for peerUserId: String) throws {
        let plaintext = try decryptFromStorage(encryptedState)
        let state = try JSONDecoder().decode(RatchetSessionState.self, from: plaintext)
        activeSessions[peerUserId] = try DoubleRatchetSession(state: state)
    }

    func exportEncryptedState(for peerUserId: String) throws -> Data? {
        guard let session = activeSessions[peerUserId] else { return nil }
        let stateData = try JSONEncoder().encode(session.exportState())
        return try encryptForStorage(stateData)
    }
}
