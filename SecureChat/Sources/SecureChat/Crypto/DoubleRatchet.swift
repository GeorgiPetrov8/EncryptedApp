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
    ///
    /// The previous implementation was `(try? JSONEncoder().encode(self)) ?? Data()`,
    /// which had two defects: on an encoding failure it silently produced an *empty*
    /// AAD (removing the header↔ciphertext binding rather than signalling), and
    /// `JSONEncoder` gives no guarantee of stable key ordering across Swift versions —
    /// a reordering between sender and receiver would break AEAD verification with no
    /// diagnosable cause.
    ///
    /// This encoding is fixed-width and byte-exact: 32 raw key bytes, then the two
    /// counters big-endian. It cannot fail and cannot be empty. `ratchetPublicKey` is
    /// guaranteed to be 32 bytes because `RatchetMessage.deserialize` rejects anything
    /// else before this is ever called on inbound data, and outbound headers always
    /// carry our own `rawRepresentation`.
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
        // FIX (Bug #4/#5): validate at the trust boundary so the AAD encoding is
        // always exactly `aadByteCount` bytes and the key is well-formed before any
        // crypto touches it.
        guard message.header.ratchetPublicKey.count == 32 else {
            throw CryptoError.invalidKeyData
        }
        return message
    }
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
    var skippedMessageKeys: [String: Data] // key = "<ratchetPubKeyBase64>:<messageNumber>"
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
    private var skippedMessageKeys: [String: SymmetricKey] = [:]

    private let maxSkip = 1000 // cap on how many out-of-order messages we'll buffer keys for

    // MARK: Construction

    /// Initiator (Alice) side: called right after `X3DH.initiate`.
    ///
    /// FIX (Bug #5): now `throws` — the DH step below can fail on a malformed peer key
    /// and must not be forced.
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
        skippedMessageKeys = state.skippedMessageKeys.reduce(into: [:]) { result, entry in
            result[entry.key] = SymmetricKey(data: entry.value)
        }
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
            skippedMessageKeys: skippedMessageKeys.reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value.withUnsafeBytes { Data($0) }
            }
        )
    }

    /// FIX (Bug #3): in-place rollback to a snapshot taken before a decrypt attempt.
    /// Deliberately private — the only legitimate caller is `decrypt`'s failure path.
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
        skippedMessageKeys = state.skippedMessageKeys.reduce(into: [:]) { result, entry in
            result[entry.key] = SymmetricKey(data: entry.value)
        }
    }

    // MARK: Encrypt / decrypt

    func encrypt(plaintext: Data) throws -> RatchetMessage {
        if sendingChainKey == nil {
            // Bob's first reply: he only now generates his own ratchet step,
            // using whatever ratchet public key he last saw from Alice.
            guard let peerKey = receivingRatchetPublicKey else { throw CryptoError.sessionNotReady }
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

    /// FIX (Bug #3): decryption is now atomic.
    ///
    /// Previously the DH ratchet step, the skipped-key derivation, the chain-key
    /// rotation and the receive counter were all committed *before* `AESGCM.open` ran.
    /// A single forged envelope therefore advanced the ratchet irreversibly and
    /// desynchronised the session permanently — a remote denial of service requiring
    /// no key material at all.
    ///
    /// We now snapshot the full session state up front and roll back on *any* thrown
    /// error, so a rejected message leaves the session exactly as it was.
    func decrypt(_ message: RatchetMessage) throws -> Data {
        let snapshot = exportState()
        do {
            return try performDecrypt(message)
        } catch {
            // Rollback must not mask the original error. `restore` can only fail if the
            // snapshot itself were malformed, which cannot happen — it came from our own
            // live state moments ago.
            try? restore(from: snapshot)
            throw error
        }
    }

    private func performDecrypt(_ message: RatchetMessage) throws -> Data {
        let incomingKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.header.ratchetPublicKey)

        // FIX (Bug #5): no more force-unwrap of `receivingRatchetPublicKey`.
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
            messageKey = stored
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

        // Only consume the buffered key once the message has actually authenticated —
        // otherwise a forged packet would burn the key for a legitimately delayed one.
        // (The snapshot rollback in `decrypt` covers this too; this ordering makes the
        // intent explicit rather than relying on it.)
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
        // Our next outgoing message will trigger a fresh sending ratchet
        // step lazily (see `encrypt`), keeping both sides in lockstep.
        sendingChainKey = nil
    }

    private func skipReceivingKeys(until target: UInt32) throws {
        guard receivingChainKey != nil else { return }
        guard target > receiveMessageNumber else { return }
        guard target - receiveMessageNumber <= UInt32(maxSkip) else { throw CryptoError.sessionNotReady }

        while receiveMessageNumber < target {
            guard let chainKey = receivingChainKey, let peerKey = receivingRatchetPublicKey else { break }
            let (messageKey, nextChainKey) = Self.kdfChainKey(chainKey)
            let id = Self.skipId(ratchetKey: peerKey.rawRepresentation, messageNumber: receiveMessageNumber)
            skippedMessageKeys[id] = messageKey
            receivingChainKey = nextChainKey
            receiveMessageNumber += 1
        }
    }

    private static func skipId(ratchetKey: Data, messageNumber: UInt32) -> String {
        "\(ratchetKey.base64EncodedString()):\(messageNumber)"
    }

    /// DH ratchet step: mix a fresh Diffie-Hellman output into the root key,
    /// producing a new root key plus a brand new chain key.
    ///
    /// FIX (Bug #5): was `try!`. The public key argument originates from
    /// `RatchetHeader.ratchetPublicKey` — i.e. straight off the network — so a
    /// malformed or hostile key crashed the entire app. Now it propagates.
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
    /// the chain key, using two distinct HMAC "constants" as domain
    /// separation (same trick Signal's spec uses).
    private static func kdfChainKey(_ chainKey: SymmetricKey) -> (messageKey: SymmetricKey, nextChainKey: SymmetricKey) {
        let messageKeyMAC = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: chainKey)
        let nextChainMAC = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: chainKey)
        return (SymmetricKey(data: Data(messageKeyMAC)), SymmetricKey(data: Data(nextChainMAC)))
    }
}
