import Foundation
import CryptoKit
import XCTest
import PeerDropNotes
import PeerDropSecurity
@testable import PeerDropGroups

final class GroupStoreAdminTests: XCTestCase {
    private var rootDirectory: URL!
    private var secretsDirectory: URL!
    private var encryptor: ChatDataEncryptor!
    private var secrets: GroupSecretsStore!

    override func setUp() {
        GroupTestURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        rootDirectory = root.appendingPathComponent("groups", isDirectory: true)
        secretsDirectory = root.appendingPathComponent("secrets", isDirectory: true)
        encryptor = GroupTestFixtures.makeEncryptor()
        secrets = GroupSecretsStore(directory: secretsDirectory, encryptor: encryptor)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootDirectory.deletingLastPathComponent())
    }

    @MainActor
    private func makeStore() -> GroupStore {
        let signingKey = localSigningKey()
        let account = GroupStore.LocalAccount(
            accountId: GroupTestFixtures.accountId,
            signingPublicKey: signingKey.publicKey.rawRepresentation
        ) { message in
            GroupCrypto.sign(message, with: signingKey)
        }
        return GroupStore(
            client: GroupTestFixtures.makeClient(),
            directory: StubGroupDirectory(signingKeys: [GroupTestFixtures.accountId: signingKey.publicKey.rawRepresentation]),
            secrets: secrets,
            rootDirectory: rootDirectory,
            localAccount: { account },
            newId: { GroupTestFixtures.eventId },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func localSigningKey() -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x31, count: 32))
    }

    private func persistGroup(
        _ id: String = GroupTestFixtures.groupId,
        owner: Bool = true,
        epoch: UInt32 = 1,
        state: GroupSummary.State = .open,
        inviteCode: String? = "OLD-CODE",
        meta: GroupMetaPlaintext? = GroupMetaPlaintext(name: "Hike"),
        awaitingKey: Bool = false,
        key: SymmetricKey? = SymmetricKey(data: Data(repeating: 0x51, count: 32))
    ) throws {
        let agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        try secrets.saveIdentity(
            GroupIdentity(
                memberId: GroupTestFixtures.memberId,
                kind: .account,
                roomPrivateKey: agreementKey.rawRepresentation,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                isOwner: owner
            ),
            for: id
        )
        if let key {
            try secrets.saveRoomKey(key, for: id, epoch: epoch)
        }
        let summary = GroupSummary(
            groupId: id,
            name: meta?.name,
            memberCount: 1,
            state: state,
            awaitingKey: awaitingKey
        )
        let record = GroupStore.PersistedGroup(
            groupId: id,
            summary: summary,
            inviteCode: inviteCode,
            meta: meta,
            myMemberId: GroupTestFixtures.memberId,
            identityKind: .account,
            joinPolicy: "accountOnly",
            isOwner: owner,
            epoch: epoch,
            rotationDue: false,
            identityEventId: nil,
            pendingIdentityNickname: nil
        )
        let url = metadataURL(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encryptor.encryptAndWrite(JSONEncoder().encode(record), to: url)
    }

    private func metadataURL(_ id: String) -> URL {
        rootDirectory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("group.enc")
    }

    private func readRecord(_ id: String = GroupTestFixtures.groupId) throws -> GroupStore.PersistedGroup {
        try JSONDecoder().decode(GroupStore.PersistedGroup.self, from: encryptor.readAndDecrypt(from: metadataURL(id)))
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
    }

    private func response<T: Encodable>(_ value: T) -> GroupTestURLProtocol.Stub {
        GroupTestURLProtocol.Stub(status: 200, body: try! JSONEncoder().encode(value))
    }

    private func wireOwner(groupId: String = GroupTestFixtures.groupId) throws -> WireMember {
        let agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let publicKey = agreementKey.publicKey.rawRepresentation
        let message = GroupCrypto.memberKeyMessage(
            groupId: groupId,
            memberId: GroupTestFixtures.memberId,
            accountId: GroupTestFixtures.accountId,
            pubKey: publicKey
        )
        return WireMember(
            memberId: GroupTestFixtures.memberId,
            kind: "account",
            accountId: GroupTestFixtures.accountId,
            joinedAt: 1_700_000_000_000,
            pubKey: publicKey.base64EncodedString(),
            pubKeySig: GroupCrypto.sign(message, with: localSigningKey()).base64EncodedString(),
            hasKey: true
        )
    }

    private func groupView(
        groupId: String = GroupTestFixtures.groupId,
        epoch: UInt32 = 1,
        seq: Int = 0,
        metaVersion: Int = 0,
        state: String = "open",
        rotationDue: Bool = false
    ) throws -> GroupView {
        GroupView(
            groupId: groupId,
            ownerMemberId: GroupTestFixtures.memberId,
            members: [try wireOwner(groupId: groupId)],
            joinPolicy: "accountOnly",
            state: state,
            epoch: epoch,
            seq: seq,
            firstSeq: 1,
            metaVersion: metaVersion,
            rotationDue: rotationDue
        )
    }

    @MainActor
    private func expectError(
        _ expected: GroupError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GroupError, expected, file: file, line: line)
        }
    }

    @MainActor
    func testNonOwnerAdminOperationsFailBeforeRequest() async throws {
        try persistGroup(owner: false)
        let store = makeStore()

        await expectError(.notOwner, operation: { try await store.kick(GroupTestFixtures.groupId, memberId: GroupTestFixtures.eventId) })
        await expectError(.notOwner, operation: { try await store.close(GroupTestFixtures.groupId) })
        await expectError(.notOwner, operation: { _ = try await store.resetInvite(GroupTestFixtures.groupId) })
        await expectError(.notOwner, operation: { try await store.updateMeta(GroupTestFixtures.groupId, GroupMetaPlaintext(name: "New")) })

        XCTAssertTrue(GroupTestURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testUpdateMetaRejectsEveryLocalLimitBeforeRequest() async throws {
        try persistGroup()
        let store = makeStore()
        let tooLargePayload = GroupMetaPlaintext(
            name: "Valid",
            photo: Data(repeating: 0x01, count: GroupLimits.photoBytes),
            background: .custom(Data(repeating: 0x02, count: GroupLimits.customBackgroundBytes))
        )
        let invalidMetas = [
            GroupMetaPlaintext(name: ""),
            GroupMetaPlaintext(name: String(repeating: "n", count: GroupLimits.nameScalars + 1)),
            GroupMetaPlaintext(name: "Valid", description: String(repeating: "d", count: GroupLimits.descriptionScalars + 1)),
            GroupMetaPlaintext(name: "Valid", photo: Data(repeating: 0x01, count: GroupLimits.photoBytes + 1)),
            GroupMetaPlaintext(name: "Valid", background: .custom(Data(repeating: 0x02, count: GroupLimits.customBackgroundBytes + 1))),
            tooLargePayload
        ]

        for meta in invalidMetas {
            await expectError(.tooLarge, operation: { try await store.updateMeta(GroupTestFixtures.groupId, meta) })
        }

        XCTAssertTrue(GroupTestURLProtocol.requests.isEmpty)
        XCTAssertEqual(try readRecord().meta?.name, "Hike")
    }

    @MainActor
    func testUpdateMetaRejectsAwaitingKeyAndRemovedGroupsLocally() async throws {
        try persistGroup(awaitingKey: true)
        let store = makeStore()

        await expectError(.awaitingKey, operation: {
            try await store.updateMeta(GroupTestFixtures.groupId, GroupMetaPlaintext(name: "New"))
        })

        var record = try readRecord()
        record.summary.state = .removed
        try encryptor.encryptAndWrite(JSONEncoder().encode(record), to: metadataURL(GroupTestFixtures.groupId))
        await expectError(.notMember, operation: {
            try await store.updateMeta(GroupTestFixtures.groupId, GroupMetaPlaintext(name: "New"))
        })

        XCTAssertTrue(GroupTestURLProtocol.requests.isEmpty)
        XCTAssertEqual(try readRecord().meta?.name, "Hike")
    }

    @MainActor
    func testKickSyncsAndRotatesWhenServerMarksRotationDue() async throws {
        try persistGroup()
        let store = makeStore()
        var viewCount = 0
        GroupTestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/kick") { return GroupTestFixtures.json("{}") }
            if path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                viewCount += 1
                let isBeforeRotation = viewCount == 1
                return try! self.response(self.groupView(
                    epoch: isBeforeRotation ? 1 : 2,
                    seq: isBeforeRotation ? 0 : 1,
                    rotationDue: isBeforeRotation
                ))
            }
            if path.hasSuffix("/events") {
                return self.response(EventsPage(events: [], firstSeq: 1))
            }
            if path.hasSuffix("/rotate") { return GroupTestFixtures.json("{\"seq\":1,\"epoch\":2}") }
            return GroupTestFixtures.json("{}", status: 500)
        }

        try await store.kick(GroupTestFixtures.groupId, memberId: GroupTestFixtures.eventId)

        XCTAssertTrue(GroupTestURLProtocol.requests.contains { $0.url?.path.hasSuffix("/rotate") == true })
        XCTAssertEqual(store.states[GroupTestFixtures.groupId]?.epoch, 2)
        XCTAssertEqual(store.states[GroupTestFixtures.groupId]?.rotationDue, false)
    }

    @MainActor
    func testReportTruncatesDecryptedTextAndOmitsExcerptWhenDisabled() async throws {
        try persistGroup()
        let store = makeStore()
        let text = String(repeating: "🌲", count: 1_001)
        let roomKey = try XCTUnwrap(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 1))
        let cipher = try GroupCrypto.sealMessage(
            GroupMessagePayload(kind: .text, text: text),
            key: roomKey,
            groupId: GroupTestFixtures.groupId,
            memberId: GroupTestFixtures.memberId,
            eventId: GroupTestFixtures.eventId,
            epoch: 1
        ).base64EncodedString()
        let message = WireEvent(
            seq: 1,
            eventId: GroupTestFixtures.eventId,
            type: "msg",
            authorMemberId: GroupTestFixtures.memberId,
            epoch: 1,
            payloadCipher: cipher,
            createdAt: 1_700_000_000_000
        )
        store.ingest([message], into: GroupTestFixtures.groupId)
        GroupTestURLProtocol.handler = { _ in GroupTestFixtures.json("{\"id\":\"report-id\"}") }

        try await store.report(GroupTestFixtures.groupId, seq: 1, reason: .spam, includeText: true)
        try await store.report(GroupTestFixtures.groupId, seq: 1, reason: .other, includeText: false)

        let firstBody = try body(GroupTestURLProtocol.requests[0])
        let excerpt = try XCTUnwrap(firstBody["excerpt"] as? String)
        let expected = String(String.UnicodeScalarView(text.unicodeScalars.prefix(1_000)))
        XCTAssertEqual(firstBody["reason"] as? String, "spam")
        XCTAssertEqual(excerpt.unicodeScalars.count, 1_000)
        XCTAssertEqual(excerpt, expected)
        XCTAssertFalse(try body(GroupTestURLProtocol.requests[1]).keys.contains("excerpt"))
    }

    @MainActor
    func testReportRejectsUnknownAndNonMessageEventsLocally() async throws {
        try persistGroup()
        let store = makeStore()
        let join = WireEvent(
            seq: 2,
            eventId: "01ARZ3NDEKTSV4RRFFQ69G5FAY",
            type: "join",
            authorMemberId: GroupTestFixtures.memberId,
            epoch: 1,
            createdAt: 1_700_000_002_000
        )
        store.ingest([join], into: GroupTestFixtures.groupId)

        await expectError(.unsupported, operation: {
            try await store.report(GroupTestFixtures.groupId, seq: 2, reason: .harassment, includeText: false)
        })
        await expectError(.notFound, operation: {
            try await store.report(GroupTestFixtures.groupId, seq: 99, reason: .other, includeText: false)
        })

        XCTAssertTrue(GroupTestURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testResetInviteUpdatesStoredInviteLink() async throws {
        try persistGroup()
        let store = makeStore()
        GroupTestURLProtocol.handler = { request in
            request.url?.path.hasSuffix("/invite/reset") == true
                ? GroupTestFixtures.json("{\"inviteCode\":\"NEW-CODE\"}")
                : GroupTestFixtures.json("{}", status: 500)
        }

        let code = try await store.resetInvite(GroupTestFixtures.groupId)

        XCTAssertEqual(code, "NEW-CODE")
        XCTAssertEqual(GroupInviteLink.parse(try XCTUnwrap(store.inviteLink(for: GroupTestFixtures.groupId)))?.code, "NEW-CODE")
        XCTAssertEqual(try readRecord().inviteCode, "NEW-CODE")
    }

    @MainActor
    func testCloseKeepsHistoryAndOnlyClosesTargetGroup() async throws {
        let otherGroupId = "01ARZ3NDEKTSV4RRFFQ69G5FB0"
        try persistGroup()
        try persistGroup(otherGroupId)
        let store = makeStore()
        let text = "history remains readable"
        let roomKey = try XCTUnwrap(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 1))
        let cipher = try GroupCrypto.sealMessage(
            GroupMessagePayload(kind: .text, text: text),
            key: roomKey,
            groupId: GroupTestFixtures.groupId,
            memberId: GroupTestFixtures.memberId,
            eventId: GroupTestFixtures.eventId,
            epoch: 1
        ).base64EncodedString()
        store.ingest([WireEvent(
            seq: 1,
            eventId: GroupTestFixtures.eventId,
            type: "msg",
            authorMemberId: GroupTestFixtures.memberId,
            epoch: 1,
            payloadCipher: cipher,
            createdAt: 1_700_000_000_000
        )], into: GroupTestFixtures.groupId)
        GroupTestURLProtocol.handler = { _ in GroupTestFixtures.json("{}") }

        try await store.close(GroupTestFixtures.groupId)
        await expectError(.closed, operation: { try await store.send(GroupTestFixtures.groupId, text: "later") })

        XCTAssertEqual(store.states[GroupTestFixtures.groupId]?.state, .closed)
        XCTAssertEqual(store.states[GroupTestFixtures.groupId]?.messages.map(\.text), [text])
        XCTAssertEqual(store.states[otherGroupId]?.state, .open)
        XCTAssertEqual(try readRecord(otherGroupId).summary.state, .open)
        XCTAssertEqual(GroupTestURLProtocol.requests.count, 1)
    }

    @MainActor
    func testUpdateMetaSealsWithCurrentEpochAndPersistsMetadata() async throws {
        let currentKey = SymmetricKey(data: Data(repeating: 0x61, count: 32))
        try persistGroup(epoch: 2, key: currentKey)
        let store = makeStore()
        let meta = GroupMetaPlaintext(name: "New name", description: "New description")
        GroupTestURLProtocol.handler = { _ in GroupTestFixtures.json("{\"seq\":4,\"metaVersion\":3}") }

        try await store.updateMeta(
            GroupTestFixtures.groupId,
            meta,
            joinPolicy: .anonymousAllowed,
            removeAnonymous: true
        )

        let request = try XCTUnwrap(GroupTestURLProtocol.requests.first)
        let requestBody = try body(request)
        let cipher = try XCTUnwrap(Data(base64Encoded: requestBody["metaCipher"] as! String))
        XCTAssertEqual(request.url?.path, "/v3/groups/\(GroupTestFixtures.groupId)/meta")
        XCTAssertEqual(requestBody["joinPolicy"] as? String, "anonymousAllowed")
        XCTAssertEqual(requestBody["removeAnonymous"] as? Bool, true)
        XCTAssertEqual(try GroupCrypto.openMeta(cipher, key: currentKey, groupId: GroupTestFixtures.groupId, epoch: 2), meta)
        XCTAssertEqual(try readRecord().meta, meta)
        XCTAssertEqual(try readRecord().joinPolicy, "anonymousAllowed")
        XCTAssertEqual(try readRecord().metaVersion, 3)
        XCTAssertEqual(store.states[GroupTestFixtures.groupId]?.meta, meta)
    }

    @MainActor
    func testTransientCloseFailureLeavesLocalStateOpen() async throws {
        try persistGroup()
        let store = makeStore()
        GroupTestURLProtocol.handler = { _ in GroupTestFixtures.json("{}", status: 500) }

        await expectError(.transient("http_500"), operation: { try await store.close(GroupTestFixtures.groupId) })

        XCTAssertEqual(store.states[GroupTestFixtures.groupId]?.state, .open)
        XCTAssertEqual(try readRecord().summary.state, .open)
    }

    @MainActor
    func testTransientUpdateMetaFailureDoesNotPersistMetadata() async throws {
        try persistGroup()
        let store = makeStore()
        GroupTestURLProtocol.handler = { _ in GroupTestFixtures.json("{}", status: 500) }

        await expectError(.transient("http_500"), operation: {
            try await store.updateMeta(GroupTestFixtures.groupId, GroupMetaPlaintext(name: "Uncommitted"))
        })

        XCTAssertEqual(store.states[GroupTestFixtures.groupId]?.meta?.name, "Hike")
        XCTAssertEqual(try readRecord().meta?.name, "Hike")
    }
}
