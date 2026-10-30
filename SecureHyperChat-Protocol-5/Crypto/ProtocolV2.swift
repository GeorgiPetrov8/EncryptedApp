import Foundation
import CryptoKit

/// Protocol version 2 — S7, S8, S40.
///
/// S7  Every message now authenticates *what it is*, not just its ratchet
///     header: the envelope id, conversation id, sender, recipient and content
///     type, plus both parties' identity keys (the X3DH "associated data"). The
///     relay (our server, or Cloudflare in front of it) can no longer change any
///     of those without the message failing to decrypt.
/// S8  Signed prekeys are signed over `"SHC-spk-v1" || key`, and login /
///     account challenges over `"SHC-challenge-v1" || nonce`. A signature made
///     for one purpose can't be passed off as the other.
/// S40 A handshake whose ephemeral key was already used can't rebuild a session
///     (`HandshakeReplayGuard`): replaying an old first message no longer resets
///     the conversation or shows old text as new.
///
/// Rolling out: install the new version on **every** phone. Existing v1 sessions
/// are dropped once (after pending messages are fetched) and the next message
/// starts a fresh v2 session automatically. While `acceptLegacy` is true a phone
/// still on the old version can keep talking (unprotected); set it to false
/// once everyone has updated.
enum ProtocolV2 {
    static let currentVersion = 2

    /// Transition switch. false = refuse v1 sessions and legacy prekey signatures.
    static let acceptLegacy = true

    /// Drop existing v1 sessions once after the upgrade so every conversation
    /// moves to v2. false = keep them until a new handshake happens naturally.
    static let resetLegacySessions = true

    static let challengeContext = Data("SHC-challenge-v1".utf8)
    static let signedPreKeyContext = Data("SHC-spk-v1".utf8)
    static let messageContext = Data("SHC-msg-v2".utf8)

    /// X3DH associated data: initiator identity || responder identity.
    static func sessionAssociatedData(
        initiatorAgreementKey: Data,
        initiatorSigningKey: Data,
        responderAgreementKey: Data,
        responderSigningKey: Data
    ) -> Data {
        initiatorAgreementKey + initiatorSigningKey + responderAgreementKey + responderSigningKey
    }
}

/// The envelope fields bound into each message's authentication tag (S7).
///
/// `createdAt` is intentionally not included: the server clamps timestamps from
/// phones whose clock runs ahead, and binding it would make those messages
/// undecryptable. The recipient clamps it as well.
struct MessageContext: Equatable {
    let envelopeId: String
    let conversationId: String
    let senderId: String
    let recipientId: String
    let contentType: String

    func encoded() -> Data {
        var out = Data()
        for field in [envelopeId, conversationId, senderId, recipientId, contentType] {
            let bytes = Data(field.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(bytes)
        }
        return out
    }
}

/// Remembers which handshake ephemeral keys already built a session with a
/// peer (S40). Public values only — hashed and kept in UserDefaults per account.
enum HandshakeReplayGuard {
    private static let limit = 200

    private static func key(owner: String, peer: String) -> String { "hsSeen.\(owner).\(peer)" }

    private static func fingerprint(_ ephemeral: Data) -> String {
        SHA256.hash(data: ephemeral).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func hasSeen(_ ephemeral: Data, owner: String, peer: String) -> Bool {
        let list = UserDefaults.standard.stringArray(forKey: key(owner: owner, peer: peer)) ?? []
        return list.contains(fingerprint(ephemeral))
    }

    static func record(_ ephemeral: Data, owner: String, peer: String) {
        let k = key(owner: owner, peer: peer)
        var list = UserDefaults.standard.stringArray(forKey: k) ?? []
        let fp = fingerprint(ephemeral)
        guard !list.contains(fp) else { return }
        list.append(fp)
        if list.count > limit { list.removeFirst(list.count - limit) }
        UserDefaults.standard.set(list, forKey: k)
    }

    /// Account deletion.
    static func removeAll(owner: String) {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("hsSeen.\(owner).") {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
}
