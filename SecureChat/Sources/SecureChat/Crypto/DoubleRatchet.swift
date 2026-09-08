import Foundation
import CryptoKit

/// Header carried in the clear alongside each ciphertext (it's authenticated
/// as AEAD associated data, but not secret — the receiving ratchet public
/// key has to be visible so the peer knows which DH step to perform).
struct RatchetHeader: Codable, Equatable {
    let ratchetPublicKey: Data
    let messageNumber: UInt32
    let previousChainLength: UInt32

    /// Fixed wire size of the AAD encoding: 32-byte key + 2 × UInt32.
    static let aadByteCount = 40

    /// FIX (Bug #4): deterministic binary encoding instead of JSON.
    func encodedForAAD() -> Data {
        var out = Data(capacity: Self.aadByteCount)
        out.append(ratchetPublicKey)
        withUnsafeBytes(of: messageNumber.bigEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: previousChainLength.bigEndian) { out.append(contentsOf: $0) }
        return out
    }
}

/// What actually gets serialized and sent over the wire / stored transiently.
struct RatchetMessage: Codable, Equatable {
    let header: RatchetHeader
    let ciphertext: Data

    func serialized() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func deserialize(_ data: Data) throws -> RatchetMessage {
        let message = try JSONDecoder().decode(RatchetMessage.self, from: data)
        guard message.header.ratchetPublicKey.count == 32 else {
            throw CryptoError.invalidKeyData
        }
        return message
    }
}

/// FIX (Bug #16): a buffered message key now carries its own metadata.
///
/// The old representation was a bare `[String: Data]`, which made both eviction
/// policies below impossible to express: there was no way to know which entry was
/// oldest, nor which ratchet generation it belonged to.
struct SkippedMessageKey: Codable, Equatable {
    let key: Data
    let createdAt: Date
    /// Monotonic counter of the receiving ratchet step this key was derived under.
    /// Lets us drop whole generations at once when the ratchet has moved well past them.
    let ratchetGeneration: UInt32
}

/// Persistable snapshot of a `DoubleRatchetSession`'s state, so a
/// conversation can survive an app relaunch. Stored encrypted-at-rest by
/// the caller (see `CryptoService.encryptForStorage`) — this struct itself
/// holds raw key material and must never be written to disk unencrypted.
struct RatchetSessionState: Codable {
    var rootKey: Data
    var sendingChainKey: Data?
    var receivingChainKey: Data?
    var sendingRatchetPrivateKey: Data
    var receivingRatchetPublicKey: Data?
    var sendMessageNumber: UInt32
    var receiveMessageNumber: UInt32
    var previousSendingChainLength: UInt32
    /// FIX (Bug #16): richer value type. Decoding tolerates the old `[String: Data]`
    /// shape so existing persisted sessions survive the upgrade (see `init(from:)`).
    var skippedMessageKeys: [String: SkippedMessageKey]
    var ratchetGeneration: UInt32

    init(
        rootKey: Data,
        sendingChainKey: Data?,
        receivingChainKey: Data?,
        sendingRatchetPrivateKey: Data,
        receivingRatchetPublicKey: Data?,
        sendMessageNumber: UInt32,
        receiveMessageNumber: UInt32,
        previousSendingChainLength: UInt32,
        skippedMessageKeys: [String: SkippedMessageKey],
        ratchetGeneration: UInt32
    ) {
        self.rootKey = rootKey
        self.sendingChainKey = sendingChainKey
        self.receivingChainKey = receivingChainKey
        self.sendingRatchetPrivateKey = sendingRatchetPrivateKey
        self.receivingRatchetPublicKey = receivingRatchetPublicKey
        self.sendMessageNumber = sendMessageNumber
        self.receiveMessageNumber = receiveMessageNumber
        self.previousSendingChainLength = previousSendingChainLength
        self.skippedMessageKeys = skippedMessageKeys
        self.ratchetGeneration = ratchetGeneration
    }

    enum CodingKeys: String, CodingKey {
        case rootKey, sendingChainKey, receivingChainKey, sendingRatchetPrivateKey
        case receivingRatchetPublicKey, sendMessageNumber, receiveMessageNumber
        case previousSendingChainLength, skippedMessageKeys, ratchetGeneration
    }

    /// FIX (Bug #16): format migration.
    ///
    /// Sessions persisted before this change hold `[String: Data]`. Failing to decode
    /// them would silently break every existing conversation, so the old shape is
    /// accepted and upgraded in place — the recovered keys are simply stamped with the
    /// current time and generation 0.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootKey = try container.decode(Data.self, forKey: .rootKey)
        sendingChainKey = try container.decodeIfPresent(Data.self, forKey: .sendingChainKey)
        receivingChainKey = try container.decodeIfPresent(Data.self, forKey: .receivingChainKey)
        sendingRatchetPrivateKey = try container.decode(Data.self, forKey: .sendingRatchetPrivateKey)
        receivingRatchetPublicKey = try container.decodeIfPresent(Data.self, forKey: .receivingRatchetPublicKey)
        sendMessageNumber = try container.decode(UInt32.self, forKey: .sendMessageNumber)
        receiveMessageNumber = try container.decode(UInt32.self, forKey: .receiveMessageNumber)
        previousSendingChainLength = try container.decode(UInt32.self, forKey: .previousSendingChainLength)
        ratchetGeneration = try container.decodeIfPresent(UInt32.self, forKey: .ratchetGeneration) ?? 0

        if let modern = try? container.decode([String: SkippedMessageKey].self, forKey: .skippedMessageKeys) {
            skippedMessageKeys = modern
        } else {
            let legacy = try container.decode([String: Data].self, forKey: .skippedMessageKeys)
            let now = Date()
            skippedMessageKeys = legacy.mapValues {
                SkippedMessageKey(key: $0, createdAt: now, ratchetGeneration: 0)
            }
        }
    }
}

/// One party's view of an ongoing Double Ratchet session with a single peer.
/// Not thread-safe by design — callers (MessagingService) serialize access
/// per conversation.
final class DoubleRatchetSession {
    private var rootKey: SymmetricKey
    private var sendingChainKey: SymmetricKey?
    private var receivingChainKey: SymmetricKey?
    private var sendingRatchetKeyPair: Curve25519.KeyAgreement.PrivateKey
    private var receivingRatchetPublicKey: Curve25519.KeyAgreement.PublicKey?
    private var sendMessageNumber: UInt32 = 0
    private var receiveMessageNumber: UInt32 = 0
    private var previousSendingChainLength: UInt32 = 0
    private var skippedMessageKeys: [String: SkippedMessageKey] = [:]
    private var ratchetGeneration: UInt32 = 0

    /// Cap on how many out-of-order messages we'll buffer keys for in a single step.
    private let maxSkip = 1000

    // FIX (Bug #16): three bounds, because `maxSkip` alone bounded nothing.
    //
    // It limited one call to `skipReceivingKeys`, but the dictionary accumulated
    // across the whole life of the session and entries were only ever removed when
    // the corresponding message actually arrived. Messages that never arrive left
    // keys behind forever — and this dictionary is serialized, encrypted and written
    // to disk on *every* message, so the cost compounds. It's also a forward-secrecy
    // problem: message keys are supposed to be short-lived.

    /// Absolute ceiling on buffered keys; the oldest are evicted past this.
    private static let maxStoredSkippedKeys = 2000
    /// Buffered keys expire regardless of the ceiling.
    private static let skippedKeyTTL: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    /// Keys from ratchet generations this far behind are dropped wholesale — the peer
    /// has demonstrably moved on and those messages can no longer arrive in order.
    private static let maxRatchetGenerationLag: UInt32 = 2

    // MARK: Construction

    /// Initiator (Alice) side: called right after `X3DH.initiate`.
    init(
        initiatorRootKey: SymmetricKey,
        peerSignedPreKeyPublic: Curve25519.KeyAgreement.PublicKey
    ) throws {
        self.rootKey = initiatorRootKey
        self.sendingRatchetKeyPair = Curve25519.KeyAgreement.PrivateKey()
        self.receivingRatchetPublicKey = peerSignedPreKeyPublic

        let (newRoot, chainKey) = try Self.dhRatchetStep(
            rootKey: initiatorRootKey,
            privateKey: sendingRatchetKeyPair,
            publicKey: peerSignedPreKeyPublic
        )
        self.rootKey = newRoot
        self.sendingChainKey = chainKey
    }

    /// Responder (Bob) side: called right after `X3DH.respond`. Bob has no
    /// sending chain yet — it's created lazily the moment he actually needs
    /// to reply, once he's seen Alice's ratchet public key.
    init(responderRootKey: SymmetricKey, mySignedPreKeyPair: Curve25519.KeyAgreement.PrivateKey) {
        self.rootKey = responderRootKey
        self.sendingRatchetKeyPair = mySignedPreKeyPair
        self.receivingRatchetPublicKey = nil
    }

    /// Restore a previously persisted session.
    init(state: RatchetSessionState) throws {
        rootKey = SymmetricKey(data: state.rootKey)
        sendingChainKey = state.sendingChainKey.map { SymmetricKey(data: $0) }
        receivingChainKey = state.receivingChainKey.map { SymmetricKey(data: $0) }
        sendingRatchetKeyPair = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.sendingRatchetPrivateKey)
        receivingRatchetPublicKey = try state.receivingRatchetPublicKey.map {
            try Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0)
        }
        sendMessageNumber = state.sendMessageNumber
        receiveMessageNumber = state.receiveMessageNumber
        previousSendingChainLength = state.previousSendingChainLength
        skippedMessageKeys = state.skippedMessageKeys
        ratchetGeneration = state.ratchetGeneration

        // FIX (Bug #16): expire on load, so a session that sat idle past the TTL
        // doesn't carry stale message keys back into memory.
        pruneSkippedKeys()
    }

    func exportState() -> RatchetSessionState {
        RatchetSessionState(
            rootKey: rootKey.withUnsafeBytes { Data($0) },
            sendingChainKey: sendingChainKey?.withUnsafeBytes { Data($0) },
            receivingChainKey: receivingChainKey?.withUnsafeBytes { Data($0) },
            sendingRatchetPrivateKey: sendingRatchetKeyPair.rawRepresentation,
            receivingRatchetPublicKey: receivingRatchetPublicKey?.rawRepresentation,
            sendMessageNumber: sendMessageNumber,
            receiveMessageNumber: receiveMessageNumber,
            previousSendingChainLength: previousSendingChainLength,
            skippedMessageKeys: skippedMessageKeys,
            ratchetGeneration: ratchetGeneration
        )
    }

    /// Diagnostic hook for tests and for bounding checks.
    var bufferedSkippedKeyCount: Int { skippedMessageKeys.count }

    /// FIX (Bug #3): in-place rollback to a snapshot taken before a decrypt attempt.
    private func restore(from state: RatchetSessionState) throws {
        rootKey = SymmetricKey(data: state.rootKey)
        sendingChainKey = state.sendingChainKey.map { SymmetricKey(data: $0) }
        receivingChainKey = state.receivingChainKey.map { SymmetricKey(data: $0) }
        sendingRatchetKeyPair = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.sendingRatchetPrivateKey)
        receivingRatchetPublicKey = try state.receivingRatchetPublicKey.map {
            try Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0)
        }
        sendMessageNumber = state.sendMessageNumber
        receiveMessageNumber = state.receiveMessageNumber
        previousSendingChainLength = state.previousSendingChainLength
        skippedMessageKeys = state.skippedMessageKeys
        ratchetGeneration = state.ratchetGeneration
    }

    // MARK: Encrypt / decrypt

    func encrypt(plaintext: Data) throws -> RatchetMessage {
        if sendingChainKey == nil {
            // Bob's first reply: he only now generates his own ratchet step,
            // using whatever ratchet public key he last saw from Alice.
            //
            // FIX (Bug #17): explicit, named guard. This is the one place a session
            // can legitimately be "not ready" — the responder has a root key but has
            // not yet seen the initiator's ratchet public key, so there is nothing to
            // ratchet against. The generic throw made it indistinguishable from a
            // corrupted session in the UI.
            guard let peerKey = receivingRatchetPublicKey else {
                throw CryptoError.awaitingFirstMessage
            }
            try advanceSendingChain(against: peerKey)
        }
        guard let chainKey = sendingChainKey else { throw CryptoError.sessionNotReady }

        let (messageKey, nextChainKey) = Self.kdfChainKey(chainKey)
        sendingChainKey = nextChainKey

        let header = RatchetHeader(
            ratchetPublicKey: sendingRatchetKeyPair.publicKey.rawRepresentation,
            messageNumber: sendMessageNumber,
            previousChainLength: previousSendingChainLength
        )
        sendMessageNumber += 1

        let ciphertext = try AESGCM.seal(plaintext: plaintext, key: messageKey, associatedData: header.encodedForAAD())
        return RatchetMessage(header: header, ciphertext: ciphertext)
    }

    /// FIX (Bug #3): decryption is atomic — a rejected message leaves the session
    /// exactly as it was.
    func decrypt(_ message: RatchetMessage) throws -> Data {
        let snapshot = exportState()
        do {
            return try performDecrypt(message)
        } catch {
            try? restore(from: snapshot)
            throw error
        }
    }

    private func performDecrypt(_ message: RatchetMessage) throws -> Data {
        let incomingKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.header.ratchetPublicKey)

        let isNewRatchetKey: Bool
        if let current = receivingRatchetPublicKey {
            isNewRatchetKey = current.rawRepresentation != incomingKey.rawRepresentation
        } else {
            isNewRatchetKey = true
        }

        if isNewRatchetKey {
            try skipReceivingKeys(until: message.header.previousChainLength)
            try performReceivingRatchetStep(newPeerPublicKey: incomingKey)
        }

        try skipReceivingKeys(until: message.header.messageNumber)

        let skipId = Self.skipId(ratchetKey: message.header.ratchetPublicKey, messageNumber: message.header.messageNumber)

        let messageKey: SymmetricKey
        let usedSkippedKey: Bool
        if let stored = skippedMessageKeys[skipId] {
            messageKey = SymmetricKey(data: stored.key)
            usedSkippedKey = true
        } else {
            guard let chainKey = receivingChainKey else { throw CryptoError.sessionNotReady }
            let (derivedKey, nextChainKey) = Self.kdfChainKey(chainKey)
            receivingChainKey = nextChainKey
            receiveMessageNumber += 1
            messageKey = derivedKey
            usedSkippedKey = false
        }

        let plaintext = try AESGCM.open(
            ciphertext: message.ciphertext,
            key: messageKey,
            associatedData: message.header.encodedForAAD()
        )

        // Only consume the buffered key once the message has actually authenticated.
        if usedSkippedKey {
            skippedMessageKeys.removeValue(forKey: skipId)
        }

        return plaintext
    }

    // MARK: Ratchet mechanics

    private func advanceSendingChain(against peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws {
        previousSendingChainLength = sendMessageNumber
        sendingRatchetKeyPair = Curve25519.KeyAgreement.PrivateKey()
        let (newRoot, newChain) = try Self.dhRatchetStep(rootKey: rootKey, privateKey: sendingRatchetKeyPair, publicKey: peerPublicKey)
        rootKey = newRoot
        sendingChainKey = newChain
        sendMessageNumber = 0
    }

    private func performReceivingRatchetStep(newPeerPublicKey: Curve25519.KeyAgreement.PublicKey) throws {
        receivingRatchetPublicKey = newPeerPublicKey
        let (newRoot, newReceiveChain) = try Self.dhRatchetStep(rootKey: rootKey, privateKey: sendingRatchetKeyPair, publicKey: newPeerPublicKey)
        rootKey = newRoot
        receivingChainKey = newReceiveChain
        receiveMessageNumber = 0
        ratchetGeneration &+= 1
        // Our next outgoing message will trigger a fresh sending ratchet
        // step lazily (see `encrypt`), keeping both sides in lockstep.
        sendingChainKey = nil

        // FIX (Bug #16): the ratchet just moved forward, so older generations are
        // now unreachable in practice — drop them rather than carrying them forever.
        pruneSkippedKeys()
    }

    private func skipReceivingKeys(until target: UInt32) throws {
        guard receivingChainKey != nil else { return }
        guard target > receiveMessageNumber else { return }
        guard target - receiveMessageNumber <= UInt32(maxSkip) else { throw CryptoError.tooManySkippedMessages }

        while receiveMessageNumber < target {
            guard let chainKey = receivingChainKey, let peerKey = receivingRatchetPublicKey else { break }
            let (messageKey, nextChainKey) = Self.kdfChainKey(chainKey)
            let id = Self.skipId(ratchetKey: peerKey.rawRepresentation, messageNumber: receiveMessageNumber)
            skippedMessageKeys[id] = SkippedMessageKey(
                key: messageKey.withUnsafeBytes { Data($0) },
                createdAt: Date(),
                ratchetGeneration: ratchetGeneration
            )
            receivingChainKey = nextChainKey
            receiveMessageNumber += 1
        }

        pruneSkippedKeys()
    }

    /// FIX (Bug #16): the three eviction rules, applied together.
    ///
    /// Order matters: expire first (cheapest and most correct), then drop stale
    /// generations, and only then fall back to evicting by age to satisfy the hard
    /// ceiling. Without the ceiling a single peer could pin memory by sending a burst
    /// of `previousChainLength` jumps.
    private func pruneSkippedKeys() {
        guard !skippedMessageKeys.isEmpty else { return }

        let cutoff = Date().addingTimeInterval(-Self.skippedKeyTTL)
        skippedMessageKeys = skippedMessageKeys.filter { $0.value.createdAt >= cutoff }

        if ratchetGeneration > Self.maxRatchetGenerationLag {
            let minimumGeneration = ratchetGeneration - Self.maxRatchetGenerationLag
            skippedMessageKeys = skippedMessageKeys.filter { $0.value.ratchetGeneration >= minimumGeneration }
        }

        guard skippedMessageKeys.count > Self.maxStoredSkippedKeys else { return }
        let survivors = skippedMessageKeys
            .sorted { $0.value.createdAt > $1.value.createdAt }
            .prefix(Self.maxStoredSkippedKeys)
        skippedMessageKeys = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    private static func skipId(ratchetKey: Data, messageNumber: UInt32) -> String {
        "\(ratchetKey.base64EncodedString()):\(messageNumber)"
    }

    /// DH ratchet step: mix a fresh Diffie-Hellman output into the root key,
    /// producing a new root key plus a brand new chain key.
    private static func dhRatchetStep(
        rootKey: SymmetricKey,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> (rootKey: SymmetricKey, chainKey: SymmetricKey) {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedData),
            salt: rootKey.withUnsafeBytes { Data($0) },
            info: Data("SecureChat DHRatchet v1".utf8),
            outputByteCount: 64
        )
        let derivedData = derived.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: derivedData.prefix(32)), SymmetricKey(data: derivedData.suffix(32)))
    }

    /// Symmetric-key ratchet step: derive this message's key and advance
    /// the chain key, using two distinct HMAC "constants" as domain separation.
    private static func kdfChainKey(_ chainKey: SymmetricKey) -> (messageKey: SymmetricKey, nextChainKey: SymmetricKey) {
        let messageKeyMAC = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: chainKey)
        let nextChainMAC = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: chainKey)
        return (SymmetricKey(data: Data(messageKeyMAC)), SymmetricKey(data: Data(nextChainMAC)))
    }
}
