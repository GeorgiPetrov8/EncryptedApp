import XCTest
import CryptoKit
import GRDB
@testable import SecureChat

/// Regression tests for the pack 4 corrections: composite primary keys, the
/// acknowledge-on-failure data loss, contact deletion, and the prekey-consuming
/// directory lookup.
final class CompositeKeyFixTests: XCTestCase {

    // MARK: - Composite primary keys

    /// The core regression. Two local accounts talking to each other derive the *same*
    /// `Conversation.id` from `deterministicId`, so with a single-column primary key
    /// the second `save` matched the first account's row and rewrote its owner.
    func testTwoAccountsKeepSeparateRowsForTheSameConversationId() throws {
        let queue = try Self.makeDatabase()
        let repository = ConversationRepository(dbQueue: queue)

        let sharedId = Conversation.deterministicId(participantIds: ["alice", "bob"])

        try repository.upsert(Conversation(
            id: sharedId, ownerUserId: "alice", participantIds: ["alice", "bob"],
            isGroup: false, createdAt: Date()
        ))
        try repository.upsert(Conversation(
            id: sharedId, ownerUserId: "bob", participantIds: ["alice", "bob"],
            isGroup: false, createdAt: Date()
        ))

        let alices = try XCTUnwrap(repository.fetch(id: sharedId, ownerUserId: "alice"))
        let bobs = try XCTUnwrap(repository.fetch(id: sharedId, ownerUserId: "bob"))

        XCTAssertEqual(alices.ownerUserId, "alice", "the recipient's save must not hijack the sender's row")
        XCTAssertEqual(bobs.ownerUserId, "bob")
        XCTAssertEqual(try repository.fetchAllSortedByRecentActivity(ownerUserId: "alice").count, 1)
        XCTAssertEqual(try repository.fetchAllSortedByRecentActivity(ownerUserId: "bob").count, 1)
    }

    /// `Message.id` is the sender's `localMessageId`, reused verbatim as the
    /// recipient's row id. Both copies must coexist.
    func testSameMessageIdCanExistForTwoAccounts() throws {
        let queue = try Self.makeDatabase()
        let conversations = ConversationRepository(dbQueue: queue)
        let messages = MessageRepository(dbQueue: queue)

        let conversationId = Conversation.deterministicId(participantIds: ["alice", "bob"])
        for owner in ["alice", "bob"] {
            try conversations.upsert(Conversation(
                id: conversationId, ownerUserId: owner, participantIds: ["alice", "bob"],
                isGroup: false, createdAt: Date()
            ))
        }

        // Alice sends; her own copy is stored first.
        try messages.insert(Self.makeMessage(
            id: "envelope-1", ownerUserId: "alice", senderId: "alice", conversationId: conversationId
        ), media: nil)

        // Bob receives the same envelope. This used to throw on a PK conflict.
        XCTAssertNoThrow(try messages.insertIfNotProcessed(
            Self.makeMessage(
                id: "envelope-1", ownerUserId: "bob", senderId: "alice", conversationId: conversationId
            ),
            envelopeId: "envelope-1", recipientUserId: "bob", senderId: "alice"
        ))

        XCTAssertEqual(try messages.fetchMessages(conversationId: conversationId, ownerUserId: "alice").count, 1)
        XCTAssertEqual(try messages.fetchMessages(conversationId: conversationId, ownerUserId: "bob").count, 1)
    }

    /// Status updates must not reach across accounts.
    func testDeliveryStatusUpdateIsScopedToOwner() throws {
        let queue = try Self.makeDatabase()
        let conversations = ConversationRepository(dbQueue: queue)
        let messages = MessageRepository(dbQueue: queue)

        for owner in ["alice", "bob"] {
            try conversations.upsert(Conversation(
                id: "conv-1", ownerUserId: owner, participantIds: ["alice", "bob"],
                isGroup: false, createdAt: Date()
            ))
            try messages.insert(Self.makeMessage(
                id: "shared", ownerUserId: owner, senderId: "alice"
            ), media: nil)
        }

        try messages.updateDeliveryStatus(messageId: "shared", ownerUserId: "alice", status: .sent)

        let alices = try XCTUnwrap(messages.fetchMessages(conversationId: "conv-1", ownerUserId: "alice").first)
        let bobs = try XCTUnwrap(messages.fetchMessages(conversationId: "conv-1", ownerUserId: "bob").first)
        XCTAssertEqual(alices.deliveryStatus, .sent)
        XCTAssertEqual(bobs.deliveryStatus, .delivered, "the other account's copy must be untouched")
    }

    /// Two accounts may each pin their own view of the same contact, and may both
    /// have a contact with the same username.
    func testUsersAreScopedPerAccount() throws {
        let repository = try Self.makeUserRepository()
        let first = IdentityKeyPair.generate()
        let second = IdentityKeyPair.generate()

        try repository.pinOrCompareIdentity(
            ownerUserId: "alice", userId: "carol", username: "carol",
            agreementKey: first.agreementPublicKey.rawRepresentation,
            signingKey: first.signingPublicKey.rawRepresentation
        )
        // Same username, different account, different pinned key — previously blocked
        // by the global UNIQUE(username).
        let check = try repository.pinOrCompareIdentity(
            ownerUserId: "bob", userId: "carol", username: "carol",
            agreementKey: second.agreementPublicKey.rawRepresentation,
            signingKey: second.signingPublicKey.rawRepresentation
        )
        XCTAssertEqual(check, .pinned, "a different account pinning is a first pin, not a mismatch")

        XCTAssertEqual(
            try repository.fetch(ownerUserId: "alice", id: "carol")?.publicKey,
            first.agreementPublicKey.rawRepresentation
        )
        XCTAssertEqual(
            try repository.fetch(ownerUserId: "bob", id: "carol")?.publicKey,
            second.agreementPublicKey.rawRepresentation
        )
    }

    /// The foreign key is composite, so a message cannot reference another account's
    /// conversation.
    func testMessageCannotReferenceAnotherAccountsConversation() throws {
        let queue = try Self.makeDatabase()
        let conversations = ConversationRepository(dbQueue: queue)
        let messages = MessageRepository(dbQueue: queue)

        try conversations.upsert(Conversation(
            id: "conv-alice", ownerUserId: "alice", participantIds: ["alice", "bob"],
            isGroup: false, createdAt: Date()
        ))

        XCTAssertThrowsError(try messages.insert(Self.makeMessage(
            id: "m-1", ownerUserId: "bob", senderId: "alice", conversationId: "conv-alice"
        ), media: nil))
    }

    // MARK: - Contact deletion

    /// Account deletion must remove the contacts that account pinned.
    func testDeletingAccountRemovesItsContactsOnly() throws {
        let repository = try Self.makeUserRepository()
        let identity = IdentityKeyPair.generate()

        for owner in ["alice", "bob"] {
            try repository.pinOrCompareIdentity(
                ownerUserId: owner, userId: "carol", username: "carol",
                agreementKey: identity.agreementPublicKey.rawRepresentation,
                signingKey: identity.signingPublicKey.rawRepresentation
            )
        }

        try repository.deleteAll(ownerUserId: "alice")

        XCTAssertNil(try repository.fetch(ownerUserId: "alice", id: "carol"))
        XCTAssertNotNil(try repository.fetch(ownerUserId: "bob", id: "carol"), "the other account keeps its contacts")
    }

    // MARK: - Directory lookups don't consume prekeys

    /// Identifying a user must not burn a one-time prekey reserved for X3DH.
    func testDirectoryLookupPreservesOneTimePreKeys() async throws {
        let store = MockBackendStore()
        _ = try await store.register(
            username: "bob",
            bundle: Self.makeUpload(userId: "bob-id", username: "bob", oneTimePreKeyCount: 3)
        )

        let before = await store.remainingOneTimePreKeyCount(userId: "bob-id")
        for _ in 0..<5 {
            _ = try await store.directoryEntry(forUserId: "bob-id")
            _ = try await store.directoryEntry(forUsername: "bob")
        }
        let after = await store.remainingOneTimePreKeyCount(userId: "bob-id")

        XCTAssertEqual(before, 3)
        XCTAssertEqual(after, 3, "a name lookup must not consume prekeys")

        // The bundle endpoint still does, which is correct — that's a real handshake.
        _ = try await store.bundle(forUserId: "bob-id")
        let afterHandshake = await store.remainingOneTimePreKeyCount(userId: "bob-id")
        XCTAssertEqual(afterHandshake, 2)
    }

    func testDirectoryEntryCarriesIdentityKeysForPinning() async throws {
        let store = MockBackendStore()
        let upload = Self.makeUpload(userId: "bob-id", username: "bob", oneTimePreKeyCount: 1)
        _ = try await store.register(username: "bob", bundle: upload)

        let entry = try await store.directoryEntry(forUserId: "bob-id")
        XCTAssertEqual(entry.username, "bob")
        XCTAssertEqual(entry.identityAgreementKey, upload.identityAgreementKey)
        XCTAssertEqual(entry.identitySigningKey, upload.identitySigningKey)
    }

    // MARK: - Backfill must not discard undelivered envelopes

    /// The acknowledge path is the one that caused irrecoverable loss: a failed
    /// envelope was acknowledged anyway, so the server dropped its only copy.
    /// Acknowledging only what is durably stored keeps the rest retryable.
    func testUnacknowledgedEnvelopeStaysQueued() async throws {
        let store = MockBackendStore()
        await store.send(Self.makeEnvelope(id: "ok", recipientId: "bob"))
        await store.send(Self.makeEnvelope(id: "failed", recipientId: "bob"))

        // Only the envelope that was durably handled is released.
        await store.acknowledge(userId: "bob", envelopeIds: ["ok"])

        let remaining = await store.pendingEnvelopes(userId: "bob", since: 0)
        XCTAssertEqual(remaining.envelopes.map(\.id), ["failed"], "the unhandled envelope must remain retryable")
    }

    // MARK: - Helpers

    private static func makeUpload(
        userId: String,
        username: String,
        oneTimePreKeyCount: Int = 2
    ) -> PreKeyBundleUpload {
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
            username: username,
            identityAgreementKey: identity.agreementPublicKey.rawRepresentation,
            identitySigningKey: identity.signingPublicKey.rawRepresentation,
            signedPreKeyId: spk.id,
            signedPreKey: spk.publicKey.rawRepresentation,
            signedPreKeySignature: spk.signature,
            oneTimePreKeys: otks
        )
    }

    private static func makeEnvelope(id: String, recipientId: String) -> EnvelopeDTO {
        EnvelopeDTO(
            id: id,
            conversationId: "conv-1",
            senderId: "alice",
            recipientId: recipientId,
            kind: .ratchet,
            handshake: nil,
            ratchetMessage: Data([0x01]),
            contentType: .text,
            createdAt: Date()
        )
    }

    private static func makeMessage(
        id: String,
        ownerUserId: String,
        senderId: String,
        conversationId: String = "conv-1",
        createdAt: Date = Date()
    ) -> Message {
        Message(
            id: id,
            ownerUserId: ownerUserId,
            conversationId: conversationId,
            senderId: senderId,
            encryptedContent: Data([0xAA]),
            contentType: .text,
            deliveryStatus: .delivered,
            createdAt: createdAt
        )
    }

    /// In-memory schema matching migration v5, with foreign keys enforced.
    private static func makeDatabase() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        try queue.write { db in
            try db.create(table: "conversations") { t in
                t.column("ownerUserId", .text).notNull()
                t.column("id", .text).notNull()
                t.column("participantIds", .text).notNull()
                t.column("isGroup", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("lastMessageAt", .datetime)
                t.primaryKey(["ownerUserId", "id"])
            }
            try db.create(table: "messages") { t in
                t.column("ownerUserId", .text).notNull()
                t.column("id", .text).notNull()
                t.column("conversationId", .text).notNull()
                t.column("senderId", .text).notNull()
                t.column("encryptedContent", .blob).notNull()
                t.column("contentType", .text).notNull()
                t.column("deliveryStatus", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["ownerUserId", "id"])
                t.foreignKey(
                    ["ownerUserId", "conversationId"],
                    references: "conversations",
                    columns: ["ownerUserId", "id"],
                    onDelete: .cascade
                )
            }
            try db.create(table: "media") { t in
                t.column("id", .text).primaryKey()
                t.column("ownerUserId", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("encryptedFilePath", .text).notNull()
                t.column("encryptedThumbnail", .blob)
                t.column("fileSize", .integer).notNull()
                t.column("mediaType", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.foreignKey(
                    ["ownerUserId", "messageId"],
                    references: "messages",
                    columns: ["ownerUserId", "id"],
                    onDelete: .cascade
                )
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

    private static func makeUserRepository() throws -> UserRepository {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(table: "users") { t in
                t.column("ownerUserId", .text).notNull()
                t.column("id", .text).notNull()
                t.column("username", .text).notNull()
                t.column("publicKey", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("identitySigningKey", .blob)
                t.column("isVerified", .boolean).notNull().defaults(to: false)
                t.column("identityChangedAt", .datetime)
                t.column("pendingIdentityAgreementKey", .blob)
                t.column("pendingIdentitySigningKey", .blob)
                t.primaryKey(["ownerUserId", "id"])
                t.uniqueKey(["ownerUserId", "username"])
            }
        }
        return UserRepository(dbQueue: queue)
    }
}
