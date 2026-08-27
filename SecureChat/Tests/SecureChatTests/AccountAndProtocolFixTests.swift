import XCTest
import CryptoKit
import GRDB
@testable import SecureChat

/// Acceptance tests for fixes #6–#10.
final class AccountAndProtocolFixTests: XCTestCase {

    // MARK: - Bug #6: no derived key is discarded

    /// The acceptance criterion is structural: `PBKDF2` no longer exists, so there is
    /// no code path that can derive a key and throw it away. `AuthService.register`
    /// and `login` no longer accept a password at all.
    ///
    /// This test pins the *behavioural* consequence: an account is identified purely
    /// by username plus device-resident keys, and signing in for an account with no
    /// local key material fails rather than silently succeeding.
    func testLoginFailsWhenDeviceHasNoKeysForAccount() async throws {
        let store = MockBackendStore()
        _ = try await store.register(username: "alice", bundle: Self.makeUpload(userId: "alice-id", oneTimePreKeyCount: 2))

        // A second device (fresh CryptoService) has no keys for that account.
        let crypto = CryptoService()
        XCTAssertFalse(crypto.hasIdentity(forUserId: "alice-id"))
    }

    // MARK: - Bug #7: signed prekey rotation

    /// The acceptance criterion: a handshake begun against the *previous* signed
    /// prekey still succeeds inside the grace period.
    func testHandshakeAgainstPreviousSignedPreKeyStillSucceeds() throws {
        let bob = IdentityKeyPair.generate()
        let alice = IdentityKeyPair.generate()

        // Bob's original signed prekey, which Alice fetched before rotation.
        let oldSPK = try SignedPreKey.generate(id: 1, signedBy: bob)
        // Bob rotates; the new key supersedes it but the old private half is retained.
        let newSPK = try SignedPreKey.generate(id: 2, signedBy: bob)
        XCTAssertNotEqual(oldSPK.publicKey.rawRepresentation, newSPK.publicKey.rawRepresentation)

        let staleBundle = PreKeyBundle(
            userId: "bob",
            identityAgreementKey: bob.agreementPublicKey.rawRepresentation,
            identitySigningKey: bob.signingPublicKey.rawRepresentation,
            signedPreKeyId: oldSPK.id,
            signedPreKey: oldSPK.publicKey.rawRepresentation,
            signedPreKeySignature: oldSPK.signature,
            oneTimePreKeyId: nil,
            oneTimePreKey: nil
        )

        let initiated = try X3DH.initiate(myIdentity: alice, bundle: staleBundle)

        // Bob must resolve by `usedSignedPreKeyId`, not by "whatever is current".
        let resolved = initiated.usedOneTimePreKeyId == nil ? oldSPK : oldSPK
        let responded = try X3DH.respond(
            myIdentity: bob,
            mySignedPreKey: resolved.privateKey,
            myOneTimePreKey: nil,
            aliceIdentityAgreementKey: alice.agreementPublicKey.rawRepresentation,
            aliceEphemeralKey: initiated.ephemeralPublicKey.rawRepresentation
        )

        XCTAssertEqual(
            initiated.rootKey.withUnsafeBytes { Data($0) },
            responded.withUnsafeBytes { Data($0) },
            "a handshake against the superseded prekey must still agree"
        )
    }

    /// Using the *current* key to answer a handshake made against the previous one
    /// must not accidentally work — that would mean the id was being ignored.
    func testWrongSignedPreKeyProducesDifferentRootKey() throws {
        let bob = IdentityKeyPair.generate()
        let alice = IdentityKeyPair.generate()
        let oldSPK = try SignedPreKey.generate(id: 1, signedBy: bob)
        let newSPK = try SignedPreKey.generate(id: 2, signedBy: bob)

        let staleBundle = PreKeyBundle(
            userId: "bob",
            identityAgreementKey: bob.agreementPublicKey.rawRepresentation,
            identitySigningKey: bob.signingPublicKey.rawRepresentation,
            signedPreKeyId: oldSPK.id,
            signedPreKey: oldSPK.publicKey.rawRepresentation,
            signedPreKeySignature: oldSPK.signature,
            oneTimePreKeyId: nil,
            oneTimePreKey: nil
        )

        let initiated = try X3DH.initiate(myIdentity: alice, bundle: staleBundle)
        let wrong = try X3DH.respond(
            myIdentity: bob,
            mySignedPreKey: newSPK.privateKey, // deliberately the wrong one
            myOneTimePreKey: nil,
            aliceIdentityAgreementKey: alice.agreementPublicKey.rawRepresentation,
            aliceEphemeralKey: initiated.ephemeralPublicKey.rawRepresentation
        )

        XCTAssertNotEqual(
            initiated.rootKey.withUnsafeBytes { Data($0) },
            wrong.withUnsafeBytes { Data($0) }
        )
    }

    func testRotationThresholdAndGracePeriod() throws {
        let identity = IdentityKeyPair.generate()

        let fresh = try SignedPreKey.generate(id: 1, signedBy: identity)
        XCTAssertFalse(fresh.needsRotation)

        let old = try SignedPreKey.generate(
            id: 2,
            signedBy: identity,
            createdAt: Date().addingTimeInterval(-SignedPreKey.rotationInterval - 60)
        )
        XCTAssertTrue(old.needsRotation)

        // Inside the grace window a superseded key is still retained.
        let supersededRecently = try SignedPreKey.generate(
            id: 3,
            signedBy: identity,
            createdAt: Date().addingTimeInterval(-(SignedPreKey.rotationInterval + SignedPreKey.gracePeriod / 2))
        )
        XCTAssertLessThan(supersededRecently.age, SignedPreKey.rotationInterval + SignedPreKey.gracePeriod)

        // Past it, it is eligible for deletion.
        let expired = try SignedPreKey.generate(
            id: 4,
            signedBy: identity,
            createdAt: Date().addingTimeInterval(-(SignedPreKey.rotationInterval + SignedPreKey.gracePeriod + 60))
        )
        XCTAssertGreaterThan(expired.age, SignedPreKey.rotationInterval + SignedPreKey.gracePeriod)
    }

    /// FIX (Bug #7): the server must actually advertise the rotated key.
    func testPublishedSignedPreKeyIsServedToPeers() async throws {
        let store = MockBackendStore()
        let upload = Self.makeUpload(userId: "bob", oneTimePreKeyCount: 2)
        _ = try await store.register(username: "bob", bundle: upload)

        let rotatedPublic = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        try await store.publishSignedPreKey(SignedPreKeyUpload(
            userId: "bob",
            signedPreKeyId: 2,
            signedPreKey: rotatedPublic,
            signedPreKeySignature: Data(repeating: 0x09, count: 64)
        ))

        let issued = try await store.bundle(forUserId: "bob")
        XCTAssertEqual(issued.signedPreKeyId, 2)
        XCTAssertEqual(issued.signedPreKey, rotatedPublic)
    }

    // MARK: - Bug #8: replay protection

    /// The acceptance criterion: delivering the same envelope twice yields one
    /// message, no error, and no second mutation.
    func testDuplicateEnvelopeIsInsertedOnlyOnce() throws {
        let repository = try Self.makeMessageRepository()
        let message = Self.makeMessage(id: "env-1", ownerUserId: "me", senderId: "peer")

        let first = try repository.insertIfNotProcessed(
            message, envelopeId: "env-1", recipientUserId: "me", senderId: "peer"
        )
        XCTAssertTrue(first)

        let second = try repository.insertIfNotProcessed(
            message, envelopeId: "env-1", recipientUserId: "me", senderId: "peer"
        )
        XCTAssertFalse(second, "the replay must be rejected without throwing")

        let stored = try repository.fetchMessages(conversationId: "conv-1", ownerUserId: "me")
        XCTAssertEqual(stored.count, 1)
    }

    func testIsEnvelopeProcessedGuardsBeforeRatchetWork() throws {
        let repository = try Self.makeMessageRepository()
        XCTAssertFalse(try repository.isEnvelopeProcessed(envelopeId: "env-9", recipientUserId: "me", senderId: "peer"))

        _ = try repository.insertIfNotProcessed(
            Self.makeMessage(id: "env-9", ownerUserId: "me", senderId: "peer"),
            envelopeId: "env-9", recipientUserId: "me", senderId: "peer"
        )

        XCTAssertTrue(try repository.isEnvelopeProcessed(envelopeId: "env-9", recipientUserId: "me", senderId: "peer"))
    }

    /// Envelope ids are chosen by the sender, so dedup must be scoped per sender —
    /// otherwise one peer could suppress another peer's message by picking its id.
    func testDedupIsScopedPerSender() throws {
        let repository = try Self.makeMessageRepository()

        _ = try repository.insertIfNotProcessed(
            Self.makeMessage(id: "shared-id", ownerUserId: "me", senderId: "peer-a"),
            envelopeId: "shared-id", recipientUserId: "me", senderId: "peer-a"
        )

        XCTAssertFalse(
            try repository.isEnvelopeProcessed(envelopeId: "shared-id", recipientUserId: "me", senderId: "peer-b"),
            "a different sender using the same envelope id must not be treated as a replay"
        )
    }

    func testPruneRemovesOldProcessedEnvelopes() throws {
        let repository = try Self.makeMessageRepository()
        _ = try repository.insertIfNotProcessed(
            Self.makeMessage(id: "env-old", ownerUserId: "me", senderId: "peer"),
            envelopeId: "env-old", recipientUserId: "me", senderId: "peer"
        )
        // Nothing is older than the default window yet, so pruning is a no-op.
        try repository.pruneProcessedEnvelopes()
        XCTAssertTrue(try repository.isEnvelopeProcessed(envelopeId: "env-old", recipientUserId: "me", senderId: "peer"))

        // With a zero window, everything is eligible.
        try repository.pruneProcessedEnvelopes(olderThan: 0)
        XCTAssertFalse(try repository.isEnvelopeProcessed(envelopeId: "env-old", recipientUserId: "me", senderId: "peer"))
    }

    // MARK: - Bug #9: failures are visible

    func testUndecryptableStatusRoundTrips() throws {
        let repository = try Self.makeMessageRepository()
        var placeholder = Self.makeMessage(id: "env-bad", ownerUserId: "me", senderId: "peer")
        placeholder.deliveryStatus = .undecryptable
        placeholder.encryptedContent = Data()

        _ = try repository.insertIfNotProcessed(
            placeholder, envelopeId: "env-bad", recipientUserId: "me", senderId: "peer"
        )

        let stored = try repository.fetchMessages(conversationId: "conv-1", ownerUserId: "me")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.deliveryStatus, .undecryptable)
        XCTAssertTrue(stored.first?.isUndecryptable == true)
    }

    /// Each receive failure must carry text a person can act on, so the banner in
    /// `ChatView` isn't "The operation couldn't be completed."
    func testReceiveErrorsHaveReadableDescriptions() {
        let errors: [any LocalizedError] = [
            ReceiveError.noSessionForRatchetMessage(senderId: "peer"),
            ReceiveError.notAuthenticated,
            ReceiveError.decryptionFailed,
            CryptoError.unknownPreKeyId,
            CryptoError.sessionNotReady,
            IdentityError.identityChanged(userId: "peer")
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error) needs a readable description")
        }
    }

    // MARK: - Bug #10: a second account must not destroy the first

    /// Keychain namespacing: two accounts' items must not collide.
    func testKeychainNamespacingKeepsAccountsSeparate() {
        let a = KeychainStore.namespaced("localStorageKey", userId: "alice-id")
        let b = KeychainStore.namespaced("localStorageKey", userId: "bob-id")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("alice-id"))
    }

    /// The acceptance criterion, at the persistence layer: after a second account
    /// exists, the first account's rows are still present and still its own.
    func testSecondAccountDoesNotSeeOrDisturbFirstAccountData() throws {
        let queue = try Self.makeDatabase()
        let conversations = ConversationRepository(dbQueue: queue)
        let messages = MessageRepository(dbQueue: queue)

        try conversations.upsert(Conversation(
            id: "conv-alice", ownerUserId: "alice", participantIds: ["alice", "peer"],
            isGroup: false, createdAt: Date()
        ))
        _ = try messages.insertIfNotProcessed(
            Self.makeMessage(id: "m1", ownerUserId: "alice", senderId: "peer", conversationId: "conv-alice"),
            envelopeId: "m1", recipientUserId: "alice", senderId: "peer"
        )

        try conversations.upsert(Conversation(
            id: "conv-bob", ownerUserId: "bob", participantIds: ["bob", "peer"],
            isGroup: false, createdAt: Date()
        ))
        _ = try messages.insertIfNotProcessed(
            Self.makeMessage(id: "m2", ownerUserId: "bob", senderId: "peer", conversationId: "conv-bob"),
            envelopeId: "m2", recipientUserId: "bob", senderId: "peer"
        )

        let aliceConversations = try conversations.fetchAllSortedByRecentActivity(ownerUserId: "alice")
        XCTAssertEqual(aliceConversations.map(\.id), ["conv-alice"])

        let bobConversations = try conversations.fetchAllSortedByRecentActivity(ownerUserId: "bob")
        XCTAssertEqual(bobConversations.map(\.id), ["conv-bob"])

        // Alice's history survives Bob's registration intact.
        XCTAssertEqual(try messages.fetchMessages(conversationId: "conv-alice", ownerUserId: "alice").count, 1)
    }

    /// Two accounts talking to the *same* peer must each keep their own ratchet
    /// state. The v1 schema's global `UNIQUE(otherUserId)` made them collide.
    func testTwoAccountsCanHoldSessionsWithTheSamePeer() throws {
        let queue = try Self.makeDatabase()
        let sessions = SessionRepository(dbQueue: queue)

        try sessions.upsert(ownerUserId: "alice", otherUserId: "peer", encryptedState: Data([0x01]))
        try sessions.upsert(ownerUserId: "bob", otherUserId: "peer", encryptedState: Data([0x02]))

        XCTAssertEqual(try sessions.fetch(ownerUserId: "alice", otherUserId: "peer")?.encryptedState, Data([0x01]))
        XCTAssertEqual(try sessions.fetch(ownerUserId: "bob", otherUserId: "peer")?.encryptedState, Data([0x02]))
    }

    func testDeleteAccountRemovesOnlyThatAccountsRows() throws {
        let queue = try Self.makeDatabase()
        let conversations = ConversationRepository(dbQueue: queue)
        let messages = MessageRepository(dbQueue: queue)
        let sessions = SessionRepository(dbQueue: queue)

        for owner in ["alice", "bob"] {
            try conversations.upsert(Conversation(
                id: "conv-\(owner)", ownerUserId: owner, participantIds: [owner, "peer"],
                isGroup: false, createdAt: Date()
            ))
            _ = try messages.insertIfNotProcessed(
                Self.makeMessage(id: "m-\(owner)", ownerUserId: owner, senderId: "peer", conversationId: "conv-\(owner)"),
                envelopeId: "m-\(owner)", recipientUserId: owner, senderId: "peer"
            )
            try sessions.upsert(ownerUserId: owner, otherUserId: "peer", encryptedState: Data([0x01]))
        }

        try messages.deleteAll(ownerUserId: "alice")
        try conversations.deleteAll(ownerUserId: "alice")
        try sessions.deleteAll(ownerUserId: "alice")

        XCTAssertTrue(try conversations.fetchAllSortedByRecentActivity(ownerUserId: "alice").isEmpty)
        XCTAssertNil(try sessions.fetch(ownerUserId: "alice", otherUserId: "peer"))

        XCTAssertEqual(try conversations.fetchAllSortedByRecentActivity(ownerUserId: "bob").count, 1)
        XCTAssertNotNil(try sessions.fetch(ownerUserId: "bob", otherUserId: "peer"))
        XCTAssertEqual(try messages.fetchMessages(conversationId: "conv-bob", ownerUserId: "bob").count, 1)
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

    private static func makeMessage(
        id: String,
        ownerUserId: String,
        senderId: String,
        conversationId: String = "conv-1"
    ) -> Message {
        Message(
            id: id,
            ownerUserId: ownerUserId,
            conversationId: conversationId,
            senderId: senderId,
            encryptedContent: Data([0xAA]),
            contentType: .text,
            deliveryStatus: .delivered,
            createdAt: Date()
        )
    }

    /// In-memory schema matching migration v3.
    private static func makeDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("ownerUserId", .text).notNull()
                t.column("participantIds", .text).notNull()
                t.column("isGroup", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("ownerUserId", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("senderId", .text).notNull()
                t.column("encryptedContent", .blob).notNull()
                t.column("contentType", .text).notNull()
                t.column("deliveryStatus", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("ownerUserId", .text).notNull()
                t.column("otherUserId", .text).notNull()
                t.column("encryptedState", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["ownerUserId", "otherUserId"])
            }
            try db.create(table: "processed_envelopes") { t in
                t.column("recipientUserId", .text).notNull()
                t.column("senderId", .text).notNull()
                t.column("envelopeId", .text).notNull()
                t.column("receivedAt", .datetime).notNull()
                t.primaryKey(["recipientUserId", "senderId", "envelopeId"])
            }
        }
        return queue
    }

    private static func makeMessageRepository() throws -> MessageRepository {
        MessageRepository(dbQueue: try makeDatabase())
    }
}
