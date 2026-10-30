import Foundation
import CryptoKit

/// Header carried in the clear alongside each ciphertext (authenticated as AEAD
/// associated data, but not secret).
struct RatchetHeader: Codable, Equatable {
    let ratchetPublicKey: Data
    let messageNumber: UInt32
    let previousChainLength: UInt32

    static let aadByteCount = 40

    func encodedForAAD() -> Data {
        var out = Data(capacity: Self.aadByteCount)
        out.append(ratchetPublicKey)
        withUnsafeBytes(of: messageNumber.bigEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: previousChainLength.bigEndian) { out.append(contentsOf: $0) }
        return out
    }
}

/// What gets serialized inside the envelope's opaque `ratchetMessage`.
///
/// `v` (protocol version) is new: absent = 1. It travels inside the base64 blob
/// the server never parses, so the server needs no change.
struct RatchetMessage: Codable, Equatable {
    let header: RatchetHeader
    let ciphertext: Data
    var v: Int? = nil

    var protocolVersion: Int { v ?? 1 }

    func serialized() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func deserialize(_ data: Data) throws -> RatchetMessage {
        let message = try JSONDecoder().decode(RatchetMessage.self, from: data)
        guard message.header.ratchetPublicKey.count == 32 else { throw CryptoError.invalidKeyData }
        guard (1...ProtocolV2.currentVersion).contains(message.protocolVersion) else { throw CryptoError.protocolMismatch }
        return message
    }
}

struct SkippedMessageKey: Codable, Equatable {
    let key: Data
    let createdAt: Date
    let ratchetGeneration: UInt32
}

/// Persistable snapshot of a `DoubleRatchetSession`. Stored encrypted at rest by
/// the caller.
struct RatchetSessionState: Codable {
    var rootKey: Data
    var sendingChainKey: Data?
    var receivingChainKey: Data?
    var sendingRatchetPrivateKey: Data
    var receivingRatchetPublicKey: Data?
    var sendMessageNumber: UInt32
    var receiveMessageNumber: UInt32
    var previousSendingChainLength: UInt32
    var skippedMessageKeys: [String: SkippedMessageKey]
    var ratchetGeneration: UInt32
    /// NEW (v2). Absent in sessions saved by older versions = 1.
    var protocolVersion: Int
    /// NEW (v2): both identities, bound into every message (S7).
    var associatedData: Data

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
        ratchetGeneration: UInt32,
        protocolVersion: Int,
        associatedData: Data
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
        self.protocolVersion = protocolVersion
        self.associatedData = associatedData
    }

    enum CodingKeys: String, CodingKey {
        case rootKey, sendingChainKey, receivingChainKey, sendingRatchetPrivateKey
        case receivingRatchetPublicKey, sendMessageNumber, receiveMessageNumber
        case previousSendingChainLength, skippedMessageKeys, ratchetGeneration
        case protocolVersion, associatedData
    }

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
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        associatedData = try container.decodeIfPresent(Data.self, forKey: .associatedData) ?? Data()

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
/// Not thread-safe by design — `MessagingService` serializes access per peer.
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

    /// 1 = legacy (header-only AAD), 2 = S7.
    private(set) var protocolVersion: Int
    private var associatedData: Data

    private let maxSkip = 1000
    private static let maxStoredSkippedKeys = 2000
    /// FIX (R9): as long as the server keeps undelivered messages (90 days). With
    /// 7 days, a message delivered after a week couldn't be decrypted any more.
    private static let skippedKeyTTL: TimeInterval = 90 * 24 * 60 * 60
    private static let maxRatchetGenerationLag: UInt32 = 2

    // MARK: Construction

    /// Initiator (Alice): right after `X3DH.initiate`.
    init(
        initiatorRootKey: SymmetricKey,
        peerSignedPreKeyPublic: Curve25519.KeyAgreement.PublicKey,
        protocolVersion: Int = 1,
        associatedData: Data = Data()
    ) throws {
        self.rootKey = initiatorRootKey
        self.sendingRatchetKeyPair = Curve25519.KeyAgreement.PrivateKey()
        self.receivingRatchetPublicKey = peerSignedPreKeyPublic
        self.protocolVersion = protocolVersion
        self.associatedData = associatedData
        let (newRoot, chainKey) = try Self.dhRatchetStep(
            rootKey: initiatorRootKey,
            privateKey: sendingRatchetKeyPair,
            publicKey: peerSignedPreKeyPublic
        )
        self.rootKey = newRoot
        self.sendingChainKey = chainKey
    }

    /// Responder (Bob): right after `X3DH.respond`.
    init(
        responderRootKey: SymmetricKey,
        mySignedPreKeyPair: Curve25519.KeyAgreement.PrivateKey,
        protocolVersion: Int = 1,
        associatedData: Data = Data()
    ) {
        self.rootKey = responderRootKey
        self.sendingRatchetKeyPair = mySignedPreKeyPair
        self.receivingRatchetPublicKey = nil
        self.protocolVersion = protocolVersion
        self.associatedData = associatedData
    }

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
        protocolVersion = state.protocolVersion
        associatedData = state.associatedData
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
            ratchetGeneration: ratchetGeneration,
            protocolVersion: protocolVersion,
            associatedData: associatedData
        )
    }

    var bufferedSkippedKeyCount: Int { skippedMessageKeys.count }

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
        protocolVersion = state.protocolVersion
        associatedData = state.associatedData
    }

    // MARK: AAD

    /// v1: the header only. v2 (S7): context tag, both identities, the header and
    /// the envelope metadata. A v2 session refuses to work without metadata.
    private func aad(header: RatchetHeader, context: MessageContext?) throws -> Data {
        guard protocolVersion >= 2 else { return header.encodedForAAD() }
        guard let context else { throw CryptoError.protocolMismatch }
        var out = ProtocolV2.messageContext
        withUnsafeBytes(of: UInt32(associatedData.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(associatedData)
        out.append(header.encodedForAAD())
        out.append(context.encoded())
        return out
    }

    // MARK: Encrypt / decrypt

    func encrypt(plaintext: Data, context: MessageContext? = nil) throws -> RatchetMessage {
        if sendingChainKey == nil {
            guard let peerKey = receivingRatchetPublicKey else {
                throw CryptoError.awaitingFirstMessage
            }
            try advanceSendingChain(against: peerKey)
        }
        guard let chainKey = sendingChainKey else { throw CryptoError.sessionNotReady }

        let header = RatchetHeader(
            ratchetPublicKey: sendingRatchetKeyPair.publicKey.rawRepresentation,
            messageNumber: sendMessageNumber,
            previousChainLength: previousSendingChainLength
        )
        let associated = try aad(header: header, context: context)

        let (messageKey, nextChainKey) = Self.kdfChainKey(chainKey)
        sendingChainKey = nextChainKey
        sendMessageNumber += 1

        let ciphertext = try AESGCM.seal(plaintext: plaintext, key: messageKey, associatedData: associated)
        return RatchetMessage(
            header: header,
            ciphertext: ciphertext,
            v: protocolVersion >= 2 ? protocolVersion : nil
        )
    }

    /// Atomic: a rejected message leaves the session exactly as it was.
    func decrypt(_ message: RatchetMessage, context: MessageContext? = nil) throws -> Data {
        // Version must match the session: no downgrade by stripping `v`.
        guard message.protocolVersion == protocolVersion else { throw CryptoError.protocolMismatch }
        let snapshot = exportState()
        do {
            return try performDecrypt(message, context: context)
        } catch {
            try? restore(from: snapshot)
            throw error
        }
    }

    private func performDecrypt(_ message: RatchetMessage, context: MessageContext?) throws -> Data {
        let associated = try aad(header: message.header, context: context)
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

        let plaintext = try AESGCM.open(ciphertext: message.ciphertext, key: messageKey, associatedData: associated)
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
        sendingChainKey = nil
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

    /// HKDF info strings unchanged on purpose (D10: changing them breaks every
    /// existing session).
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
            info: Data("HyperChat DHRatchet v1".utf8),
            outputByteCount: 64
        )
        let derivedData = derived.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: derivedData.prefix(32)), SymmetricKey(data: derivedData.suffix(32)))
    }

    private static func kdfChainKey(_ chainKey: SymmetricKey) -> (messageKey: SymmetricKey, nextChainKey: SymmetricKey) {
        let messageKeyMAC = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: chainKey)
        let nextChainMAC = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: chainKey)
        return (SymmetricKey(data: Data(messageKeyMAC)), SymmetricKey(data: Data(nextChainMAC)))
    }
}
