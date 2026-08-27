import XCTest
import CryptoKit
import GRDB
@testable import HyperChat

/// Acceptance tests for fixes #1–#5.
final class CryptoFixTests: XCTestCase {

    // MARK: - Bug #1: one-time prekey pool

    /// Three different accounts start a conversation with the same user; each must
    /// receive a *distinct* one-time prekey. Previously all three got id 0, and only
    /// the first could ever derive a matching root key.
    func testEachPeerReceivesADistinctOneTimePreKey() async throws {
        let store = MockBackendStore()
        let upload = Self.makeUpload(userId: "bob", oneTimePreKeyCount: 3)
        _ = try await store.register(username: "bob", bundle: upload)

        let first = try await store.bundle(forUserId: "bob")
        let second = try await store.bundle(forUserId: "bob")
        let third = try await store.bundle(forUserId: "bob")

        let ids = [first.oneTimePreKeyId, second.oneTimePreKeyId, third.oneTimePreKeyId]
        XCTAssertEqual(ids.compactMap { $0 }.count, 3, "every peer must get a one-time prekey while the pool lasts")
        XCTAssertEqual(Set(ids.compactMap { $0 }).count, 3, "one-time prekeys must never be handed out twice")
    }

    /// The fourth peer arrives after the pool is exhausted and must still get a usable
    /// bundle — just without a one-time prekey, so both sides skip dh4.
    func testExhaustedPoolYieldsBundleWithoutOneTimePreKey() async throws {
        let store = MockBackendStore()
        _ = try await store.register(username: "bob", bundle: Self.makeUpload(userId: "bob", oneTimePreKeyCount: 3))

        for _ in 0..<3 { _ = try await store.bundle(forUserId: "bob") }
        let exhausted = try await store.bundle(forUserId: "bob")

        XCTAssertNil(exhausted.oneTimePreKeyId)
        XCTAssertNil(exhausted.oneTimePreKey)
        XCTAssertFalse(exhausted.signedPreKey.isEmpty, "the rest of the bundle must still be usable")
    }

    /// An X3DH handshake must produce the same root key on both sides whether or not a
    /// one-time prekey was included.
    func testX3DHAgreesWithAndWithoutOneTimePreKey() throws {
        for includeOTK in [true, false] {
            let alice = IdentityKeyPair.generate()
            let bob = IdentityKeyPair.generate()
            let bobSPK = try SignedPreKey.generate(id: 1, signedBy: bob)
            let bobOTK = Curve25519.KeyAgreement.PrivateKey()

            let bundle = PreKeyBundle(
                userId: "bob",
                identityAgreementKey: bob.agreementPublicKey.rawRepresentation,
                identitySigningKey: bob.signingPublicKey.rawRepresentation,
                signedPreKeyId: bobSPK.id,
                signedPreKey: bobSPK.publicKey.rawRepresentation,
                signedPreKeySignature: bobSPK.signature,
                oneTimePreKeyId: includeOTK ? 7 : nil,
                oneTimePreKey: includeOTK ? bobOTK.publicKey.rawRepresentation : nil
            )

            let initiated = try X3DH.initiate(myIdentity: alice, bundle: bundle)
            let responded = try X3DH.respond(
                myIdentity: bob,
                mySignedPreKey: bobSPK.privateKey,
                myOneTimePreKey: includeOTK ? bobOTK : nil,
                aliceIdentityAgreementKey: alice.agreementPublicKey.rawRepresentation,
                aliceEphemeralKey: initiated.ephemeralPublicKey.rawRepresentation
            )

            XCTAssertEqual(
                initiated.rootKey.withUnsafeBytes { Data($0) },
                responded.withUnsafeBytes { Data($0) },
                "root keys must agree (includeOTK: \(includeOTK))"
            )
        }
    }

    /// Replenishing must be idempotent — a retried call must not duplicate ids.
    func testReplenishIsIdempotent() async throws {
        let store = MockBackendStore()
        _ = try await store.register(username: "bob", bundle: Self.makeUpload(userId: "bob", oneTimePreKeyCount: 1))

        let fresh = [OneTimePreKeyPublic(id: 50, publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)]
        try await store.replenishOneTimePreKeys(userId: "bob", keys: fresh)
        try await store.replenishOneTimePreKeys(userId: "bob", keys: fresh)

        let remaining = await store.remainingOneTimePreKeyCount(userId: "bob")
        XCTAssertEqual(remaining, 2, "the duplicate replenish must be ignored")
    }

    // MARK: - Bug #2: identity pinning and safety numbers

    /// Both sides must compute an identical safety number regardless of argument order.
    func testSafetyNumberIsOrderIndependent() {
        let alice = IdentityKeyPair.generate()
        let bob = IdentityKeyPair.generate()

        let fromAlice = SafetyNumber.format(
            myAgreementKey: alice.agreementPublicKey.rawRepresentation,
            mySigningKey: alice.signingPublicKey.rawRepresentation,
            peerAgreementKey: bob.agreementPublicKey.rawRepresentation,
            peerSigningKey: bob.signingPublicKey.rawRepresentation
        )
        let fromBob = SafetyNumber.format(
            myAgreementKey: bob.agreementPublicKey.rawRepresentation,
            mySigningKey: bob.signingPublicKey.rawRepresentation,
            peerAgreementKey: alice.agreementPublicKey.rawRepresentation,
            peerSigningKey: alice.signingPublicKey.rawRepresentation
        )

        XCTAssertEqual(fromAlice, fromBob)
        XCTAssertEqual(fromAlice.split(separator: " ").count, SafetyNumber.groupCount)
    }

    func testSafetyNumberChangesWhenIdentityChanges() {
        let alice = IdentityKeyPair.generate()
        let bob = IdentityKeyPair.generate()
        let impostor = IdentityKeyPair.generate()

        let genuine = SafetyNumber.format(
            myAgreementKey: alice.agreementPublicKey.rawRepresentation,
            mySigningKey: alice.signingPublicKey.rawRepresentation,
            peerAgreementKey: bob.agreementPublicKey.rawRepresentation,
            peerSigningKey: bob.signingPublicKey.rawRepresentation
        )
        let swapped = SafetyNumber.format(
            myAgreementKey: alice.agreementPublicKey.rawRepresentation,
            mySigningKey: alice.signingPublicKey.rawRepresentation,
            peerAgreementKey: impostor.agreementPublicKey.rawRepresentation,
            peerSigningKey: impostor.signingPublicKey.rawRepresentation
        )

        XCTAssertNotEqual(genuine, swapped, "a swapped bundle must produce a visibly different safety number")
    }

    /// A swapped identity must be detected, recorded as pending, and must not silently
    /// overwrite the pinned key.
    func testIdentitySwapIsDetectedAndBlocked() throws {
        let repository = try Self.makeUserRepository()
        let genuine = IdentityKeyPair.generate()
        let impostor = IdentityKeyPair.generate()

        let first = try repository.pinOrCompareIdentity(
            userId: "bob",
            username: "bob",
            agreementKey: genuine.agreementPublicKey.rawRepresentation,
            signingKey: genuine.signingPublicKey.rawRepresentation
        )
        XCTAssertEqual(first, .pinned)

        let again = try repository.pinOrCompareIdentity(
            userId: "bob",
            username: "bob",
            agreementKey: genuine.agreementPublicKey.rawRepresentation,
            signingKey: genuine.signingPublicKey.rawRepresentation
        )
        XCTAssertEqual(again, .matches)

        let swapped = try repository.pinOrCompareIdentity(
            userId: "bob",
            username: "bob",
            agreementKey: impostor.agreementPublicKey.rawRepresentation,
            signingKey: impostor.signingPublicKey.rawRepresentation
        )
        XCTAssertEqual(swapped, .changed)

        let stored = try XCTUnwrap(repository.fetch(id: "bob"))
        XCTAssertEqual(stored.publicKey, genuine.agreementPublicKey.rawRepresentation, "the pinned key must survive the attempt")
        XCTAssertEqual(stored.pendingIdentityAgreementKey, impostor.agreementPublicKey.rawRepresentation)
        XCTAssertTrue(stored.hasUnacknowledgedIdentityChange)

        // Until acknowledged, further attempts stay blocked.
        let stillBlocked = try repository.pinOrCompareIdentity(
            userId: "bob",
            username: "bob",
            agreementKey: impostor.agreementPublicKey.rawRepresentation,
            signingKey: impostor.signingPublicKey.rawRepresentation
        )
        XCTAssertEqual(stillBlocked, .changePending)

        try repository.acknowledgeIdentityChange(userId: "bob")
        let promoted = try XCTUnwrap(repository.fetch(id: "bob"))
        XCTAssertEqual(promoted.publicKey, impostor.agreementPublicKey.rawRepresentation)
        XCTAssertFalse(promoted.isVerified, "a newly accepted identity must start unverified")
        XCTAssertFalse(promoted.hasUnacknowledgedIdentityChange)
    }

    // MARK: - Bug #3: transactional decrypt

    /// The acceptance criterion: valid → forged → valid. The third message must still
    /// decrypt, proving the forged one left no trace in the session state.
    func testForgedMessageDoesNotDesynchroniseSession() throws {
        let (alice, bob) = try Self.makePairedSessions()

        let first = try alice.encrypt(plaintext: Data("one".utf8))
        XCTAssertEqual(try bob.decrypt(first), Data("one".utf8))

        let second = try alice.encrypt(plaintext: Data("two".utf8))

        var tamperedCiphertext = second.ciphertext
        tamperedCiphertext[tamperedCiphertext.index(before: tamperedCiphertext.endIndex)] ^= 0xFF
        let forged = RatchetMessage(header: second.header, ciphertext: tamperedCiphertext)

        XCTAssertThrowsError(try bob.decrypt(forged), "a tampered ciphertext must be rejected")

        // The genuine message must still work — this is what the old code broke.
        XCTAssertEqual(try bob.decrypt(second), Data("two".utf8))

        let third = try alice.encrypt(plaintext: Data("three".utf8))
        XCTAssertEqual(try bob.decrypt(third), Data("three".utf8))
    }

    /// A forged message must not consume a buffered key belonging to a legitimately
    /// delayed message.
    func testForgedMessageDoesNotConsumeSkippedKey() throws {
        let (alice, bob) = try Self.makePairedSessions()

        let m0 = try alice.encrypt(plaintext: Data("zero".utf8))
        let m1 = try alice.encrypt(plaintext: Data("one".utf8))

        // Deliver out of order so m0's key gets buffered.
        XCTAssertEqual(try bob.decrypt(m1), Data("one".utf8))

        var tampered = m0.ciphertext
        tampered[tampered.startIndex] ^= 0x01
        XCTAssertThrowsError(try bob.decrypt(RatchetMessage(header: m0.header, ciphertext: tampered)))

        XCTAssertEqual(try bob.decrypt(m0), Data("zero".utf8), "the buffered key must survive the forgery")
    }

    // MARK: - Bug #4: AAD encoding

    func testAADEncodingIsFixedWidthAndStable() {
        let header = RatchetHeader(
            ratchetPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            messageNumber: 258,
            previousChainLength: 1
        )

        let encoded = header.encodedForAAD()
        XCTAssertEqual(encoded.count, RatchetHeader.aadByteCount)
        XCTAssertEqual(encoded, header.encodedForAAD(), "encoding must be deterministic")
        XCTAssertFalse(encoded.isEmpty)

        // Counters are big-endian: 258 == 0x00000102
        XCTAssertEqual(Array(encoded.suffix(8)), [0, 0, 1, 2, 0, 0, 0, 1])
    }

    func testAADBindsHeaderToCiphertext() throws {
        let (alice, bob) = try Self.makePairedSessions()
        let message = try alice.encrypt(plaintext: Data("bound".utf8))

        let rewrittenHeader = RatchetHeader(
            ratchetPublicKey: message.header.ratchetPublicKey,
            messageNumber: message.header.messageNumber &+ 1,
            previousChainLength: message.header.previousChainLength
        )
        let rewritten = RatchetMessage(header: rewrittenHeader, ciphertext: message.ciphertext)

        XCTAssertThrowsError(try bob.decrypt(rewritten), "rewriting the header must invalidate the AEAD tag")
    }

    // MARK: - Bug #5: no force-try on network input

    func testMalformedRatchetKeyThrowsInsteadOfCrashing() throws {
        let (alice, bob) = try Self.makePairedSessions()
        let message = try alice.encrypt(plaintext: Data("hello".utf8))

        // Not a valid 32-byte Curve25519 key.
        let badHeader = RatchetHeader(
            ratchetPublicKey: Data(repeating: 0xAB, count: 8),
            messageNumber: message.header.messageNumber,
            previousChainLength: message.header.previousChainLength
        )
        XCTAssertThrowsError(try bob.decrypt(RatchetMessage(header: badHeader, ciphertext: message.ciphertext)))
    }

    func testDeserializeRejectsWrongLengthRatchetKey() throws {
        let header = RatchetHeader(
            ratchetPublicKey: Data(repeating: 0x01, count: 31),
            messageNumber: 0,
            previousChainLength: 0
        )
        let payload = try JSONEncoder().encode(RatchetMessage(header: header, ciphertext: Data()))
        XCTAssertThrowsError(try RatchetMessage.deserialize(payload))
    }

    // MARK: - Helpers

    private static func makeUpload(userId: String, oneTimePreKeyCount: Int) -> PreKeyBundleUpload {
        let identity = IdentityKeyPair.generate()
        let spk = try! SignedPreKey.generate(id: 1, signedBy: identity)
        let otks = (0..<oneTimePreKeyCount).map { index in
            OneTimePreKeyPublic(
                id: UInt32(index),
                publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            )
        }
        return PreKeyBundleUpload(
            userId: userId,
            identityAgreementKey: identity.agreementPublicKey.rawRepresentation,
            identitySigningKey: identity.signingPublicKey.rawRepresentation,
            signedPreKeyId: spk.id,
            signedPreKey: spk.publicKey.rawRepresentation,
            signedPreKeySignature: spk.signature,
            oneTimePreKeys: otks
        )
    }

    /// Builds an Alice/Bob session pair the same way `MessagingService` does.
    private static func makePairedSessions() throws -> (alice: DoubleRatchetSession, bob: DoubleRatchetSession) {
        let alice = IdentityKeyPair.generate()
        let bob = IdentityKeyPair.generate()
        let bobSPK = try SignedPreKey.generate(id: 1, signedBy: bob)
        let bobOTK = Curve25519.KeyAgreement.PrivateKey()

        let bundle = PreKeyBundle(
            userId: "bob",
            identityAgreementKey: bob.agreementPublicKey.rawRepresentation,
            identitySigningKey: bob.signingPublicKey.rawRepresentation,
            signedPreKeyId: bobSPK.id,
            signedPreKey: bobSPK.publicKey.rawRepresentation,
            signedPreKeySignature: bobSPK.signature,
            oneTimePreKeyId: 1,
            oneTimePreKey: bobOTK.publicKey.rawRepresentation
        )

        let initiated = try X3DH.initiate(myIdentity: alice, bundle: bundle)
        let bobRootKey = try X3DH.respond(
            myIdentity: bob,
            mySignedPreKey: bobSPK.privateKey,
            myOneTimePreKey: bobOTK,
            aliceIdentityAgreementKey: alice.agreementPublicKey.rawRepresentation,
            aliceEphemeralKey: initiated.ephemeralPublicKey.rawRepresentation
        )

        let aliceSession = try DoubleRatchetSession(
            initiatorRootKey: initiated.rootKey,
            peerSignedPreKeyPublic: bobSPK.publicKey
        )
        let bobSession = DoubleRatchetSession(
            responderRootKey: bobRootKey,
            mySignedPreKeyPair: bobSPK.privateKey
        )
        return (aliceSession, bobSession)
    }

    /// In-memory `users` table matching schema v2.
    private static func makeUserRepository() throws -> UserRepository {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(table: "users") { t in
                t.column("id", .text).primaryKey()
                t.column("username", .text).notNull().unique()
                t.column("publicKey", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("identitySigningKey", .blob)
                t.column("isVerified", .boolean).notNull().defaults(to: false)
                t.column("identityChangedAt", .datetime)
                t.column("pendingIdentityAgreementKey", .blob)
                t.column("pendingIdentitySigningKey", .blob)
            }
        }
        return UserRepository(dbQueue: queue)
    }
}
