import Foundation
import CryptoKit

/// Key material in portable form, for the encrypted backup (account recovery).
///
/// Only ever exists in memory and inside a password-encrypted backup file —
/// never written anywhere in this form.
struct ExportedKeyMaterial: Codable {
    struct SignedPreKeyEntry: Codable {
        let id: UInt32
        let privateKey: Data
        let signature: Data
        let createdAt: Date
    }

    struct OneTimePreKeyEntry: Codable {
        let id: UInt32
        let privateKey: Data
    }

    /// 64 bytes: X25519 agreement key + Ed25519 signing key.
    let identity: Data
    let signedPreKeys: [SignedPreKeyEntry]
    let currentSignedPreKeyId: UInt32
    let oneTimePreKeys: [OneTimePreKeyEntry]
    let nextOneTimePreKeyId: UInt32
}

/// Central point of contact for all cryptographic operations. Owns:
///  - the device's identity key + signed prekeys + one-time prekeys
///  - the device-local storage key (encrypts history / session state at rest)
///  - in-memory active `DoubleRatchetSession`s, keyed by peer user id
///
/// Bound to exactly one account at a time via `activate(userId:)`; every
/// Keychain item is namespaced by that userId (Bug #10).
final class CryptoService {
    private let keychain = KeychainStore()
    private(set) var signedPreKey: SignedPreKey?
    private(set) var identity: IdentityKeyPair?
    private(set) var activeUserId: String?

    private var activeSessions: [String: DoubleRatchetSession] = [:]
    private var cachedStorageKey: SymmetricKey?

    static let oneTimePreKeyBatchSize = 20

    private enum Keys {
        static let identity = "identityKeyPair"
        static let oneTimePreKeysPrefix = "otk_"
        static let oneTimePreKeyLiveIds = "otkLiveIds"
        static let oneTimePreKeyNextId = "otkNextId"
        static let storageKey = "localStorageKey"

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

    func hasIdentity(forUserId userId: String) -> Bool {
        keychain.loadIfPresent(key: KeychainStore.namespaced(Keys.identity, userId: userId)) != nil
    }

    var hasIdentity: Bool {
        guard let userId = activeUserId else { return false }
        return hasIdentity(forUserId: userId)
    }

    // MARK: Identity lifecycle

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

        try createStorageKey()

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

    func loadIdentityFromKeychain(userId: String) throws {
        activate(userId: userId)
        let identityData = try keychain.load(key: try account(Keys.identity))
        identity = try IdentityKeyPair.from(rawRepresentation: identityData)
        signedPreKey = try loadCurrentSignedPreKey()
    }

    /// The only path that destroys key material, and it is explicit.
    func deleteAccount(userId: String) {
        keychain.deleteAll(forUserId: userId)
        if activeUserId == userId { deactivate() }
    }

    // MARK: Backup export / import (account recovery)

    /// Everything needed to be this account on another device.
    ///
    /// Ratchet sessions are deliberately NOT included: a session restored from
    /// an older backup is behind the peer, and reusing its message counters
    /// would produce messages the peer can't decrypt. A restored device starts
    /// fresh sessions instead (see `MessagingService.reestablishSessions`).
    func exportKeyMaterial() throws -> ExportedKeyMaterial {
        guard let identity else { throw CryptoError.noActiveAccount }

        let signedPreKeys = loadSignedPreKeyLiveIds()
            .compactMap { try? signedPreKey(withId: $0) }
            .map {
                ExportedKeyMaterial.SignedPreKeyEntry(
                    id: $0.id,
                    privateKey: $0.privateKey.rawRepresentation,
                    signature: $0.signature,
                    createdAt: $0.createdAt
                )
            }

        var oneTimePreKeys: [ExportedKeyMaterial.OneTimePreKeyEntry] = []
        for id in loadLiveOneTimePreKeyIds() {
            if let data = keychain.loadIfPresent(key: try account(Keys.oneTimePreKeysPrefix + String(id))) {
                oneTimePreKeys.append(.init(id: id, privateKey: data))
            }
        }

        return ExportedKeyMaterial(
            identity: identity.rawRepresentation(),
            signedPreKeys: signedPreKeys,
            currentSignedPreKeyId: try loadCurrentSignedPreKeyId(),
            oneTimePreKeys: oneTimePreKeys,
            nextOneTimePreKeyId: loadNextOneTimePreKeyId()
        )
    }

    /// Writes imported key material into this device's Keychain and creates a
    /// fresh storage key. All-or-nothing: on any failure the partial import is
    /// removed.
    func importKeyMaterial(_ material: ExportedKeyMaterial, userId: String) throws {
        guard !hasIdentity(forUserId: userId) else { throw CryptoError.identityAlreadyExists }

        do {
            activate(userId: userId)
            let identity = try IdentityKeyPair.from(rawRepresentation: material.identity)

            var liveSignedIds: [UInt32] = []
            for entry in material.signedPreKeys {
                let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: entry.privateKey)
                // A signed prekey that wasn't signed by this identity means the
                // file was tampered with or mixed up between accounts.
                guard identity.signingPublicKey.isValidSignature(
                    entry.signature, for: privateKey.publicKey.rawRepresentation
                ) else {
                    throw CryptoError.invalidSignature
                }
                try keychain.save(key: try account(Keys.signedPreKeyPrefix + String(entry.id)), data: entry.privateKey)
                try keychain.save(key: try account(Keys.signedPreKeySignaturePrefix + String(entry.id)), data: entry.signature)
                try keychain.save(
                    key: try account(Keys.signedPreKeyCreatedAtPrefix + String(entry.id)),
                    data: Self.encode(entry.createdAt)
                )
                liveSignedIds.append(entry.id)
            }
            guard liveSignedIds.contains(material.currentSignedPreKeyId) else { throw CryptoError.unknownPreKeyId }
            try saveSignedPreKeyLiveIds(liveSignedIds)
            try saveCurrentSignedPreKeyId(material.currentSignedPreKeyId)

            for entry in material.oneTimePreKeys {
                _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: entry.privateKey)
                try keychain.save(key: try account(Keys.oneTimePreKeysPrefix + String(entry.id)), data: entry.privateKey)
            }
            try saveLiveOneTimePreKeyIds(material.oneTimePreKeys.map(\.id))
            try saveNextOneTimePreKeyId(material.nextOneTimePreKeyId)

            // New device, new storage key — the old one never leaves its device.
            try createStorageKey()

            // Identity last: `hasIdentity` keys off it, so a crash mid-import
            // leaves nothing that looks like a usable account.
            try keychain.save(key: try account(Keys.identity), data: identity.rawRepresentation())
            self.identity = identity
            self.signedPreKey = try loadCurrentSignedPreKey()
        } catch {
            deleteAccount(userId: userId)
            throw error
        }
    }

    private func createStorageKey() throws {
        let storageKey = AESGCM.randomKey()
        try keychain.save(
            key: try account(Keys.storageKey),
            data: storageKey.withUnsafeBytes { Data($0) },
            requireUserPresence: true
        )
        cachedStorageKey = storageKey
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

    // MARK: Fixed-width encoding (Bug #20)

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

    private func storageKey() throws -> SymmetricKey {
        if let cachedStorageKey { return cachedStorageKey }
        let data = try keychain.load(key: try account(Keys.storageKey))
        let key = SymmetricKey(data: data)
        cachedStorageKey = key
        return key
    }

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

    func clearSession(for peerUserId: String) {
        activeSessions[peerUserId] = nil
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

extension CryptoService {
    /// Signs `message` with the active account's Ed25519 identity key.
    ///
    /// Used for the server's login and account-deletion challenges. The
    /// signing key is taken from the stored identity and checked against the
    /// public signing key, so a wrong half can never be used by mistake.
    func signWithIdentity(_ message: Data) throws -> Data {
        guard let identity else { throw CryptoError.noActiveAccount }
        let raw = try identity.rawRepresentation()
        let expected = identity.signingPublicKey.rawRepresentation

        guard raw.count >= 64 else { throw CryptoError.invalidKeyData }
        let candidates = [(raw.count - 32)..<raw.count, 0..<32]
        for range in candidates {
            if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw.subdata(in: range)),
               key.publicKey.rawRepresentation == expected {
                return try key.signature(for: message)
            }
        }
        throw CryptoError.invalidKeyData
    }

    /// Signs a server challenge after checking it's for `userId`.
    func signChallenge(_ challenge: LoginChallenge, expectedUserId: String? = nil) throws -> Data {
        if let expectedUserId, challenge.userId != expectedUserId {
            throw AuthError.userIdMismatch
        }
        guard let nonce = Data(base64Encoded: challenge.nonce) else { throw CryptoError.invalidKeyData }
        return try signWithIdentity(nonce)
    }
}
