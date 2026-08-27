import XCTest
import CryptoKit
@testable import SecureChat

final class CryptoTests: XCTestCase {

    func testAESGCMRoundTrip() throws {
        let key = AESGCM.randomKey()
        let plaintext = Data("hello secure world".utf8)
        let ciphertext = try AESGCM.seal(plaintext: plaintext, key: key)
        let decrypted = try AESGCM.open(ciphertext: ciphertext, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testPBKDF2IsDeterministicForSameInputs() {
        let salt = PBKDF2.randomSalt()
        let key1 = PBKDF2.deriveKey(password: Data("correct horse".utf8), salt: salt, iterations: 1000)
        let key2 = PBKDF2.deriveKey(password: Data("correct horse".utf8), salt: salt, iterations: 1000)
        XCTAssertEqual(key1.withUnsafeBytes { Data($0) }, key2.withUnsafeBytes { Data($0) })
    }

    func testX3DHProducesMatchingSharedSecret() throws {
        let bob = IdentityKeyPair.generate()
        let bobSPK = try SignedPreKey.generate(id: 1, signedBy: bob)
        let bobOTK = OneTimePreKey.generateBatch(count: 1).first!

        let bundle = PreKeyBundle(
            userId: "bob",
            identityAgreementKey: bob.agreementPublicKey.rawRepresentation,
            identitySigningKey: bob.signingPublicKey.rawRepresentation,
            signedPreKeyId: bobSPK.id,
            signedPreKey: bobSPK.publicKey.rawRepresentation,
            signedPreKeySignature: bobSPK.signature,
            oneTimePreKeyId: bobOTK.id,
            oneTimePreKey: bobOTK.publicKey.rawRepresentation
        )

        let alice = IdentityKeyPair.generate()
        let initiatorResult = try X3DH.initiate(myIdentity: alice, bundle: bundle)

        let responderKey = try X3DH.respond(
            myIdentity: bob,
            mySignedPreKey: bobSPK.privateKey,
            myOneTimePreKey: bobOTK.privateKey,
            aliceIdentityAgreementKey: alice.agreementPublicKey.rawRepresentation,
            aliceEphemeralKey: initiatorResult.ephemeralPublicKey.rawRepresentation
        )

        XCTAssertEqual(
            initiatorResult.rootKey.withUnsafeBytes { Data($0) },
            responderKey.withUnsafeBytes { Data($0) }
        )
    }

    func testDoubleRatchetBasicRoundTrip() throws {
        let (aliceSession, bobSession) = try Self.makeConnectedSessions()

        let message1 = try aliceSession.encrypt(plaintext: Data("Hey Bob!".utf8))
        let decrypted1 = try bobSession.decrypt(message1)
        XCTAssertEqual(String(data: decrypted1, encoding: .utf8), "Hey Bob!")

        let reply1 = try bobSession.encrypt(plaintext: Data("Hey Alice!".utf8))
        let decryptedReply1 = try aliceSession.decrypt(reply1)
        XCTAssertEqual(String(data: decryptedReply1, encoding: .utf8), "Hey Alice!")

        // A second round after the ratchet has stepped both directions.
        let message2 = try aliceSession.encrypt(plaintext: Data("How are you?".utf8))
        let decrypted2 = try bobSession.decrypt(message2)
        XCTAssertEqual(String(data: decrypted2, encoding: .utf8), "How are you?")
    }

    func testDoubleRatchetHandlesOutOfOrderDelivery() throws {
        let (aliceSession, bobSession) = try Self.makeConnectedSessions()

        let m1 = try aliceSession.encrypt(plaintext: Data("one".utf8))
        let m2 = try aliceSession.encrypt(plaintext: Data("two".utf8))
        let m3 = try aliceSession.encrypt(plaintext: Data("three".utf8))

        // Deliver out of order: 2, then 1, then 3.
        let d2 = try bobSession.decrypt(m2)
        let d1 = try bobSession.decrypt(m1)
        let d3 = try bobSession.decrypt(m3)

        XCTAssertEqual(String(data: d1, encoding: .utf8), "one")
        XCTAssertEqual(String(data: d2, encoding: .utf8), "two")
        XCTAssertEqual(String(data: d3, encoding: .utf8), "three")
    }

    func testDoubleRatchetSessionStateSurvivesSerialization() throws {
        let (aliceSession, bobSession) = try Self.makeConnectedSessions()

        let priming = try aliceSession.encrypt(plaintext: Data("priming".utf8))
        _ = try bobSession.decrypt(priming)

        // Simulate an app relaunch: serialize Alice's state and rebuild a
        // *fresh* session object from it, then stop using the original
        // in-memory object entirely (mirroring what really happens on
        // relaunch — the old object is just gone).
        let restoredAlice = try DoubleRatchetSession(state: aliceSession.exportState())

        let message = try restoredAlice.encrypt(plaintext: Data("after restore".utf8))
        let decrypted = try bobSession.decrypt(message)
        XCTAssertEqual(String(data: decrypted, encoding: .utf8), "after restore")
    }

    private static func makeConnectedSessions() throws -> (alice: DoubleRatchetSession, bob: DoubleRatchetSession) {
        let bob = IdentityKeyPair.generate()
        let bobSPK = try SignedPreKey.generate(id: 1, signedBy: bob)

        let bundle = PreKeyBundle(
            userId: "bob",
            identityAgreementKey: bob.agreementPublicKey.rawRepresentation,
            identitySigningKey: bob.signingPublicKey.rawRepresentation,
            signedPreKeyId: bobSPK.id,
            signedPreKey: bobSPK.publicKey.rawRepresentation,
            signedPreKeySignature: bobSPK.signature,
            oneTimePreKeyId: nil,
            oneTimePreKey: nil
        )

        let alice = IdentityKeyPair.generate()
        let initiatorResult = try X3DH.initiate(myIdentity: alice, bundle: bundle)
        let rootKeyForBob = try X3DH.respond(
            myIdentity: bob,
            mySignedPreKey: bobSPK.privateKey,
            myOneTimePreKey: nil,
            aliceIdentityAgreementKey: alice.agreementPublicKey.rawRepresentation,
            aliceEphemeralKey: initiatorResult.ephemeralPublicKey.rawRepresentation
        )

        let aliceSession = DoubleRatchetSession(
            initiatorRootKey: initiatorResult.rootKey,
            peerSignedPreKeyPublic: bobSPK.publicKey
        )
        let bobSession = DoubleRatchetSession(responderRootKey: rootKeyForBob, mySignedPreKeyPair: bobSPK.privateKey)

        return (aliceSession, bobSession)
    }
}
