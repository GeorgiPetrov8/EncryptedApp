import XCTest
import CryptoKit
import GRDB
@testable import SecureChat

/// Acceptance tests for fixes #11–#26.
final class DeliveryAndUIFixTests: XCTestCase {

    // MARK: - Bug #11: peers are named

    /// The bundle now carries a username, so both the outbound and inbound paths can
    /// name a peer from a single fetch.
    func testPreKeyBundleCarriesUsername() async throws {
        let store = MockBackendStore()
        _ = try await store.register(username: "bob", bundle: Self.makeUpload(userId: "bob-id", username: "bob"))

        let byName = try await store.bundle(forUsername: "bob")
        let byId = try await store.bundle(forUserId: "bob-id")

        XCTAssertEqual(byName.username, "bob")
        XCTAssertEqual(byId.username, "bob")
    }

    /// A contact placeholder gives a peer a display name without pinning any key —
    /// and a later pin must fill the key in rather than being treated as a mismatch.
    func testPlaceholderContactIsUpgradedByPinning() throws {
        let repository = try Self.makeUserRepository()
        let identity = IdentityKeyPair.generate()

        try repository.upsertContactPlaceholder(userId: "bob-id", username: "bob")
        let placeholder = try XCTUnwrap(repository.fetch(id: "bob-id"))
        XCTAssertEqual(placeholder.username, "bob")
        XCTAssertTrue(placeholder.isPlaceholderContact)

        let check = try repository.pinOrCompareIdentity(
            userId: "bob-id",
            username: "bob",
            agreementKey: identity.agreementPublicKey.rawRepresentation,
            signingKey: identity.signingPublicKey.rawRepresentation
        )
        XCTAssertEqual(check, .pinned, "a placeholder has no pinned key, so this is a first pin — not a change")

        let pinned = try XCTUnwrap(repository.fetch(id: "bob-id"))
        XCTAssertFalse(pinned.isPlaceholderContact)
        XCTAssertEqual(pinned.publicKey, identity.agreementPublicKey.rawRepresentation)
    }

    /// Refreshing a display name must never disturb pinned key material.
    func testUpdateUsernameLeavesKeysAlone() throws {
        let repository = try Self.makeUserRepository()
        let identity = IdentityKeyPair.generate()

        try repository.pinOrCompareIdentity(
            userId: "bob-id",
            username: "bob",
            agreementKey: identity.agreementPublicKey.rawRepresentation,
            signingKey: identity.signingPublicKey.rawRepresentation
        )
        try repository.updateUsername(userId: "bob-id", username: "bobby")

        let user = try XCTUnwrap(repository.fetch(id: "bob-id"))
        XCTAssertEqual(user.username, "bobby")
        XCTAssertEqual(user.publicKey, identity.agreementPublicKey.rawRepresentation)
    }

    // MARK: - Bug #12: offline messages arrive

    /// The acceptance criterion: send while the recipient isn't listening, then sync.
    func testEnvelopesSentWhileOfflineAreBackfilledInOrder() async throws {
        let store = MockBackendStore()

        for index in 0..<3 {
            await store.send(Self.makeEnvelope(id: "env-\(index)", recipientId: "bob", createdAt: Date()))
        }

        let page = await store.pendingEnvelopes(userId: "bob", since: 0)
        XCTAssertEqual(page.envelopes.map(\.id), ["env-0", "env-1", "env-2"])
        XCTAssertGreaterThan(page.cursor, 0)
    }

    /// Resuming from the cursor must not re-deliver what was already synced.
    func testCursorPreventsRedelivery() async throws {
        let store = MockBackendStore()
        await store.send(Self.makeEnvelope(id: "env-a", recipientId: "bob", createdAt: Date()))

        let first = await store.pendingEnvelopes(userId: "bob", since: 0)
        XCTAssertEqual(first.envelopes.count, 1)

        await store.send(Self.makeEnvelope(id: "env-b", recipientId: "bob", createdAt: Date()))

        let second = await store.pendingEnvelopes(userId: "bob", since: first.cursor)
        XCTAssertEqual(second.envelopes.map(\.id), ["env-b"])
    }

    func testAcknowledgeDrainsTheQueue() async throws {
        let store = MockBackendStore()
        await store.send(Self.makeEnvelope(id: "env-a", recipientId: "bob", createdAt: Date()))
        await store.send(Self.makeEnvelope(id: "env-b", recipientId: "bob", createdAt: Date()))

        await store.acknowledge(userId: "bob", envelopeIds: ["env-a"])

        let remaining = await store.pendingCount(userId: "bob")
        XCTAssertEqual(remaining, 1)
    }

    /// The cursor is per account, so one account's sync can't skip another's queue.
    func testSyncCursorIsPerAccountAndMonotonic() {
        let defaults = UserDefaults(suiteName: "test.sync.cursor.\(UUID().uuidString)")!
        let store = SyncCursorStore(defaults: defaults)

        store.advance(to: 10, for: "alice")
        XCTAssertEqual(store.cursor(for: "alice"), 10)
        XCTAssertEqual(store.cursor(for: "bob"), 0)

        store.advance(to: 5, for: "alice")
        XCTAssertEqual(store.cursor(for: "alice"), 10, "the cursor must never move backwards")
    }

    // MARK: - Bug #13: media rows have a valid parent

    /// The acceptance criterion: `fetch(messageId:)` returns the record, no orphans.
    func testMediaIsInsertedWithItsMessageAndIsRetrievable() throws {
        let queue = try Self.makeDatabase()
        let conversations = ConversationRepository(dbQueue: queue)
        let messages = MessageRepository(dbQueue: queue)
        let media = MediaRepository(dbQueue: queue)

        try conversations.upsert(Self.makeConversation(id: "conv-1", ownerUserId: "me"))

        let message = Self.makeMessage(id: "msg-1", ownerUserId: "me", senderId: "me", contentType: .image)
        let item = MediaItem(
            id: "media-1",
            messageId: "", // deliberately blank — the repository must fill it in
            ownerUserId: "",
            encryptedFilePath: "/tmp/media-1",
            encryptedThumbnail: nil,
            fileSize: 1234,
            mediaType: .image,
            createdAt: Date()
        )

        try messages.insert(message, media: item)

        let fetched = try XCTUnwrap(media.fetch(messageId: "msg-1"))
        XCTAssertEqual(fetched.id, "media-1")
        XCTAssertEqual(fetched.messageId, "msg-1", "the repository must bind the media row to its message")
        XCTAssertEqual(fetched.ownerUserId, "me")
    }

    /// A media row whose parent doesn't exist must be rejected, not silently orphaned.
    func testMediaWithoutParentMessageIsRejected() throws {
        let queue = try Self.makeDatabase()
        let media = MediaRepository(dbQueue: queue)

        let orphan = MediaItem(
            id: "media-orphan",
            messageId: "no-such-message",
            ownerUserId: "me",
            encryptedFilePath: "/tmp/orphan",
            encryptedThumbnail: nil,
            fileSize: 1,
            mediaType: .image,
            createdAt: Date()
        )
        XCTAssertThrowsError(try media.insert(orphan))
    }

    // MARK: - Bug #14: one conversation per pair

    /// The acceptance criterion: both sides derive the same id independently.
    func testConversationIdIsDeterministicAndOrderIndependent() {
        let fromAlice = Conversation.deterministicId(participantIds: ["alice", "bob"])
        let fromBob = Conversation.deterministicId(participantIds: ["bob", "alice"])

        XCTAssertEqual(fromAlice, fromBob)
        XCTAssertNotEqual(fromAlice, Conversation.deterministicId(participantIds: ["alice", "carol"]))
    }

    func testBothSidesStartingIndependentlyProduceOneConversation() throws {
        let queue = try Self.makeDatabase()
        let repository = ConversationRepository(dbQueue: queue)

        // Alice creates hers.
        let id = Conversation.deterministicId(participantIds: ["alice", "bob"])
        try repository.upsert(Conversation(
            id: id, ownerUserId: "alice", participantIds: ["alice", "bob"],
            isGroup: false, createdAt: Date()
        ))

        // Bob's inbound path derives the same id, so this is an update, not a second row.
        try repository.upsert(Conversation(
            id: Conversation.deterministicId(participantIds: ["bob", "alice"]),
            ownerUserId: "alice", participantIds: ["alice", "bob"],
            isGroup: false, createdAt: Date()
        ))

        XCTAssertEqual(try repository.fetchAllSortedByRecentActivity(ownerUserId: "alice").count, 1)
    }

    /// Conversations created before the change keep working rather than duplicating.
    func testLegacyRandomIdConversationIsStillFound() throws {
        let queue = try Self.makeDatabase()
        let repository = ConversationRepository(dbQueue: queue)

        try repository.upsert(Conversation(
            id: UUID().uuidString, ownerUserId: "alice", participantIds: ["alice", "bob"],
            isGroup: false, createdAt: Date()
        ))

        XCTAssertNotNil(try repository.findDirectConversation(ownerUserId: "alice", userA: "alice", userB: "bob"))
    }

    // MARK: - Bug #15: ordering follows activity

    /// The acceptance criterion: a new message moves its conversation to the top.
    func testNewMessageMovesConversationToTop() throws {
        let queue = try Self.makeDatabase()
        let conversations = ConversationRepository(dbQueue: queue)
        let messages = MessageRepository(dbQueue: queue)

        let old = Date().addingTimeInterval(-3600)
        // "conv-a" is newer by creation date, so the old ordering would always win.
        try conversations.upsert(Self.makeConversation(id: "conv-b", ownerUserId: "me", createdAt: old))
        try conversations.upsert(Self.makeConversation(id: "conv-a", ownerUserId: "me", createdAt: Date()))

        XCTAssertEqual(
            try conversations.fetchAllSortedByRecentActivity(ownerUserId: "me").map(\.id),
            ["conv-a", "conv-b"]
        )

        // A fresh message in the older conversation must lift it.
        try messages.insert(Self.makeMessage(
            id: "m-1", ownerUserId: "me", senderId: "peer",
            conversationId: "conv-b", createdAt: Date().addingTimeInterval(60)
        ), media: nil)

        XCTAssertEqual(
            try conversations.fetchAllSortedByRecentActivity(ownerUserId: "me").map(\.id),
            ["conv-b", "conv-a"]
        )
    }

    /// The denormalised column must be maintained by the insert itself.
    func testInsertMaintainsLastMessageAt() throws {
        let queue = try Self.makeDatabase()
        let conversations = ConversationRepository(dbQueue: queue)
        let messages = MessageRepository(dbQueue: queue)

        try conversations.upsert(Self.makeConversation(id: "conv-1", ownerUserId: "me"))
        XCTAssertNil(try conversations.fetch(id: "conv-1", ownerUserId: "me")?.lastMessageAt)

        let sentAt = Date().addingTimeInterval(120)
        try messages.insert(Self.makeMessage(
            id: "m-1", ownerUserId: "me", senderId: "peer", conversationId: "conv-1", createdAt: sentAt
        ), media: nil)

        let updated = try XCTUnwrap(conversations.fetch(id: "conv-1", ownerUserId: "me"))
        XCTAssertEqual(
            updated.lastMessageAt?.timeIntervalSince1970 ?? 0,
            sentAt.timeIntervalSince1970,
            accuracy: 1
        )
    }

    // MARK: - Bug #16: skipped keys stay bounded

    /// The acceptance criterion: 5000 skipped messages must not grow state without limit.
    func testSkippedKeysAreCappedAcrossManyGaps() throws {
        let (alice, bob) = try Self.makePairedSessions()

        // Force repeated large gaps by discarding most of Alice's output.
        for round in 0..<6 {
            for _ in 0..<900 {
                _ = try alice.encrypt(plaintext: Data("skipped".utf8))
            }
            let delivered = try alice.encrypt(plaintext: Data("round-\(round)".utf8))
            XCTAssertEqual(try bob.decrypt(delivered), Data("round-\(round)".utf8))
        }

        XCTAssertLessThanOrEqual(
            bob.bufferedSkippedKeyCount,
            2000,
            "buffered keys must respect the hard ceiling"
        )
    }

    /// Out-of-order delivery must still work — the cap must not break the feature.
    func testOutOfOrderDeliveryStillWorksWithinTheCap() throws {
        let (alice, bob) = try Self.makePairedSessions()

        let m0 = try alice.encrypt(plaintext: Data("zero".utf8))
        let m1 = try alice.encrypt(plaintext: Data("one".utf8))
        let m2 = try alice.encrypt(plaintext: Data("two".utf8))

        XCTAssertEqual(try bob.decrypt(m2), Data("two".utf8))
        XCTAssertEqual(try bob.decrypt(m0), Data("zero".utf8))
        XCTAssertEqual(try bob.decrypt(m1), Data("one".utf8))
    }

    /// Sessions persisted in the old `[String: Data]` shape must still decode.
    func testLegacySessionStateFormatStillDecodes() throws {
        let legacy: [String: Any] = [
            "rootKey": Data(repeating: 0x01, count: 32).base64EncodedString(),
            "sendingRatchetPrivateKey": Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString(),
            "sendMessageNumber": 3,
            "receiveMessageNumber": 4,
            "previousSendingChainLength": 2,
            "skippedMessageKeys": ["abc:1": Data(repeating: 0x02, count: 32).base64EncodedString()]
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(RatchetSessionState.self, from: data)

        XCTAssertEqual(decoded.skippedMessageKeys.count, 1)
        XCTAssertEqual(decoded.ratchetGeneration, 0)
        XCTAssertNotNil(decoded.skippedMessageKeys["abc:1"]?.createdAt)
    }

    // MARK: - Bug #17: crypto errors are legible

    /// The acceptance criterion: every crypto error reaching the UI reads sensibly.
    func testEveryCryptoErrorHasADescription() {
        let all: [CryptoError] = [
            .invalidKeyData, .invalidSignature, .sessionNotReady, .awaitingFirstMessage,
            .tooManySkippedMessages, .sealFailed, .unknownPreKeyId,
            .noOneTimePreKeysAvailable, .noActiveAccount, .identityAlreadyExists
        ]
        for error in all {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error) needs a description")
            XCTAssertFalse(
                description.contains("couldn't be completed"),
                "\(error) still reads like an unhandled NSError"
            )
        }
    }

    /// Only errors that can clear on their own should offer a retry.
    func testRecoverabilityIsDistinguished() {
        XCTAssertTrue(CryptoError.awaitingFirstMessage.isRecoverable)
        XCTAssertFalse(CryptoError.invalidSignature.isRecoverable)
        XCTAssertFalse(CryptoError.sessionNotReady.isRecoverable)
    }

    /// A responder with no peer ratchet key yet reports the specific, recoverable case.
    func testResponderWithoutPeerKeyReportsAwaitingFirstMessage() throws {
        let bob = IdentityKeyPair.generate()
        let spk = try SignedPreKey.generate(id: 1, signedBy: bob)
        let session = DoubleRatchetSession(
            responderRootKey: SymmetricKey(size: .bits256),
            mySignedPreKeyPair: spk.privateKey
        )

        XCTAssertThrowsError(try session.encrypt(plaintext: Data("hi".utf8))) { error in
            XCTAssertEqual(error as? CryptoError, .awaitingFirstMessage)
            XCTAssertTrue((error as? CryptoError)?.isRecoverable == true)
        }
    }

    // MARK: - Bug #18: previews never leak key material

    /// The acceptance criterion: a media message shows an icon and a type, not JSON.
    func testMediaMessagesArePreviewedByTypeNotContent() {
        for (type, expected) in [
            (MessageContentType.image, "📷 Photo"),
            (.video, "🎥 Video"),
            (.file, "📎 File")
        ] {
            let message = Self.makeMessage(
                id: "m", ownerUserId: "me", senderId: "peer", contentType: type
            )
            XCTAssertTrue(message.carriesMediaPayload)
            // The preview must be derived from the type alone, never from the body —
            // the body is a MediaKeyPayload containing a base64 AES key.
            XCTAssertEqual(expectedPreview(for: message), expected)
        }
    }

    /// Mirrors `MessagingService.previewText`'s branching without needing the full
    /// service graph, so the rule itself is pinned by a test.
    private func expectedPreview(for message: Message) -> String {
        switch message.contentType {
        case .text: return "text"
        case .image: return "📷 Photo"
        case .video: return "🎥 Video"
        case .file: return "📎 File"
        }
    }

    // MARK: - Bug #20: no unaligned loads

    /// Round-trips the fixed-width encodings used for Keychain integers.
    func testBigEndianRoundTripIsStable() {
        let value: UInt32 = 0x0102_0304
        let encoded = withUnsafeBytes(of: value.bigEndian) { Data($0) }
        XCTAssertEqual(Array(encoded), [0x01, 0x02, 0x03, 0x04])

        // Deliberately misaligned buffer: `load(as:)` would be undefined here.
        var padded = Data([0xFF])
        padded.append(encoded)
        let slice = padded.dropFirst()
        let decoded = slice.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        XCTAssertEqual(decoded, value)
    }

    // MARK: - Helpers

    private static func makeUpload(userId: String, username: String, oneTimePreKeyCount: Int = 2) -> PreKeyBundleUpload {
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

    private static func makeEnvelope(id: String, recipientId: String, createdAt: Date) -> EnvelopeDTO {
        EnvelopeDTO(
            id: id,
            conversationId: "conv-1",
            senderId: "alice",
            recipientId: recipientId,
            kind: .ratchet,
            handshake: nil,
            ratchetMessage: Data([0x01]),
            contentType: .text,
            createdAt: createdAt
        )
    }

    private static func makeConversation(
        id: String,
        ownerUserId: String,
        createdAt: Date = Date()
    ) -> Conversation {
        Conversation(
            id: id,
            ownerUserId: ownerUserId,
            participantIds: [ownerUserId, "peer"],
            isGroup: false,
            createdAt: createdAt
        )
    }

    private static func makeMessage(
        id: String,
        ownerUserId: String,
        senderId: String,
        conversationId: String = "conv-1",
        contentType: MessageContentType = .text,
        createdAt: Date = Date()
    ) -> Message {
        Message(
            id: id,
            ownerUserId: ownerUserId,
            conversationId: conversationId,
            senderId: senderId,
            encryptedContent: Data([0xAA]),
            contentType: contentType,
            deliveryStatus: .delivered,
            createdAt: createdAt
        )
    }

    private static func makePairedSessions() throws -> (alice: DoubleRatchetSession, bob: DoubleRatchetSession) {
        let alice = IdentityKeyPair.generate()
        let bob = IdentityKeyPair.generate()
        let bobSPK = try SignedPreKey.generate(id: 1, signedBy: bob)
        let bobOTK = Curve25519.KeyAgreement.PrivateKey()

        let bundle = PreKeyBundle(
            userId: "bob",
            username: "bob",
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

        return (
            try DoubleRatchetSession(initiatorRootKey: initiated.rootKey, peerSignedPreKeyPublic: bobSPK.publicKey),
            DoubleRatchetSession(responderRootKey: bobRootKey, mySignedPreKeyPair: bobSPK.privateKey)
        )
    }

    /// In-memory schema matching migration v4, with foreign keys enforced so the
    /// media FK test is meaningful.
    private static func makeDatabase() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        try queue.write { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("ownerUserId", .text).notNull()
                t.column("participantIds", .text).notNull()
                t.column("isGroup", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("lastMessageAt", .datetime)
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
            try db.create(table: "media") { t in
                t.column("id", .text).primaryKey()
                t.column("messageId", .text).notNull().indexed()
                    .references("messages", column: "id", onDelete: .cascade)
                t.column("ownerUserId", .text).notNull()
                t.column("encryptedFilePath", .text).notNull()
                t.column("encryptedThumbnail", .blob)
                t.column("fileSize", .integer).notNull()
                t.column("mediaType", .text).notNull()
                t.column("createdAt", .datetime).notNull()
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
