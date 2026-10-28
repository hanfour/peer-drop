import Foundation
import CryptoKit
import XCTest
import PeerDropSecurity
@testable import PeerDropGroups

final class GroupStoreSyncTests: XCTestCase {
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
    private func store(ids: [String] = [GroupTestFixtures.groupId, GroupTestFixtures.memberId]) -> GroupStore {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x31, count: 32))
        let account = GroupStore.LocalAccount(accountId: GroupTestFixtures.accountId, signingPublicKey: key.publicKey.rawRepresentation) { message in
            GroupCrypto.sign(message, with: key)
        }
        return GroupStore(
            client: GroupTestFixtures.makeClient(), directory: StubGroupDirectory(signingKeys: [:]), secrets: secrets,
            rootDirectory: rootDirectory, localAccount: { account }, newId: GroupTestFixtures.makeIdGenerator(ids),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    @MainActor
    private func createGroup(_ id: String, in store: GroupStore) async throws {
        GroupTestURLProtocol.handler = { _ in
            GroupTestFixtures.json("{\"groupId\":\"\(id)\",\"inviteCode\":\"JOIN1234\"}", status: 201)
        }
        _ = try await store.create(name: "Hike", description: nil, category: nil, joinPolicy: "accountOnly")
        GroupTestURLProtocol.requests.removeAll()
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
    }

    private func wireMember(_ id: String, kind: String = "anon", hasKey: Bool = true) -> WireMember {
        WireMember(
            memberId: id, kind: kind, accountId: kind == "account" ? GroupTestFixtures.accountId : nil,
            joinedAt: 1_700_000_000_000, pubKey: Data(repeating: 0x41, count: 32).base64EncodedString(),
            hasKey: hasKey
        )
    }

    private func view(
        groupId: String = GroupTestFixtures.groupId,
        memberId: String = GroupTestFixtures.memberId,
        peers: [String] = [],
        epoch: UInt32 = 1,
        seq: Int = 0,
        firstSeq: Int = 1,
        metaVersion: Int = 0,
        hasKey: Bool = true
    ) -> GroupView {
        GroupView(
            groupId: groupId, ownerMemberId: memberId,
            members: [wireMember(memberId, kind: "account", hasKey: hasKey)] + peers.map { wireMember($0) },
            joinPolicy: "accountOnly", state: "open", epoch: epoch, seq: seq, firstSeq: firstSeq,
            metaVersion: metaVersion, rotationDue: false
        )
    }

    private func response<T: Encodable>(_ value: T, status: Int = 200) -> GroupTestURLProtocol.Stub {
        GroupTestURLProtocol.Stub(status: status, body: try! JSONEncoder().encode(value))
    }

    private func event(
        _ seq: Int,
        id: String,
        author: String = GroupTestFixtures.memberId,
        epoch: UInt32 = 1,
        cipher: String? = nil,
        type: String = "msg"
    ) -> WireEvent {
        WireEvent(
            seq: seq, eventId: id, type: type, authorMemberId: author, epoch: epoch,
            payloadCipher: cipher, createdAt: 1_700_000_000_000 + seq * 1_000
        )
    }

    private func sealedText(
        _ text: String,
        eventId: String,
        author: String = GroupTestFixtures.memberId,
        epoch: UInt32 = 1,
        key: SymmetricKey? = nil,
        aadEventId: String? = nil,
        groupId: String = GroupTestFixtures.groupId
    ) throws -> String {
        let roomKey = try key ?? XCTUnwrap(secrets.roomKey(for: groupId, epoch: epoch))
        return try GroupCrypto.sealMessage(
            GroupMessagePayload(kind: .text, text: text), key: roomKey, groupId: groupId,
            memberId: author, eventId: aadEventId ?? eventId, epoch: epoch
        ).base64EncodedString()
    }

    private func eventsPage(_ events: [WireEvent], firstSeq: Int = 1, nextSince: Int? = nil) -> GroupTestURLProtocol.Stub {
        response(EventsPage(events: events, firstSeq: firstSeq, nextSince: nextSince))
    }

    private func setAwaitingKey(_ groupId: String) throws {
        let url = rootDirectory.appendingPathComponent(groupId, isDirectory: true).appendingPathComponent("group.enc")
        let data = try encryptor.readAndDecrypt(from: url)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var summary = try XCTUnwrap(record["summary"] as? [String: Any])
        summary["awaitingKey"] = true
        record["summary"] = summary
        try encryptor.encryptAndWrite(JSONSerialization.data(withJSONObject: record), to: url)
    }

    @MainActor
    func testBackfillDecryptsAndOrdersBySeq() async throws {
        let groupStore = store()
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        let peerId = "01ARZ3NDEKTSV4RRFFQ69G5B00"
        let first = event(1, id: "01ARZ3NDEKTSV4RRFFQ69G5B01", author: peerId, cipher: try sealedText("first", eventId: "01ARZ3NDEKTSV4RRFFQ69G5B01", author: peerId))
        let second = event(2, id: "01ARZ3NDEKTSV4RRFFQ69G5B02", author: peerId, cipher: try sealedText("second", eventId: "01ARZ3NDEKTSV4RRFFQ69G5B02", author: peerId))
        var pageRequests = 0
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" { return self.response(self.view(peers: [peerId], seq: 2)) }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" {
                pageRequests += 1
                return pageRequests == 1 ? self.eventsPage([first], nextSince: 1) : self.eventsPage([second])
            }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await groupStore.sync(GroupTestFixtures.groupId)

        let state = try XCTUnwrap(groupStore.states[GroupTestFixtures.groupId])
        XCTAssertEqual(state.messages.map(\.text), ["first", "second"])
        XCTAssertEqual(state.messages.map(\.seq), [1, 2])
        XCTAssertEqual(pageRequests, 2)
    }

    @MainActor
    func testSameEventFromSocketAndBackfillAppearsOnce() async throws {
        let groupStore = store()
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        let peerId = "01ARZ3NDEKTSV4RRFFQ69G5B00"
        let wire = event(1, id: "01ARZ3NDEKTSV4RRFFQ69G5B01", author: peerId, cipher: try sealedText("once", eventId: "01ARZ3NDEKTSV4RRFFQ69G5B01", author: peerId))
        groupStore.ingest([wire], into: GroupTestFixtures.groupId)
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" { return self.response(self.view(peers: [peerId], seq: 1)) }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" { return self.eventsPage([wire]) }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await groupStore.sync(GroupTestFixtures.groupId)

        XCTAssertEqual(groupStore.states[GroupTestFixtures.groupId]?.messages.filter { $0.eventId == wire.eventId }.count, 1)
    }

    @MainActor
    func testSendRetryReusesEventId() async throws {
        let groupStore = store(ids: [GroupTestFixtures.groupId, GroupTestFixtures.memberId, "01ARZ3NDEKTSV4RRFFQ69G5B00"])
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" {
                return GroupTestURLProtocol.requests.filter { $0.url?.path == request.url?.path }.count == 1
                    ? .init(status: 0, body: Data(), error: URLError(.timedOut))
                    : GroupTestFixtures.json("{\"seq\":1}")
            }
            return GroupTestFixtures.json("{}", status: 500)
        }

        try await groupStore.send(GroupTestFixtures.groupId, text: "hello")

        let requests = GroupTestURLProtocol.requests.filter { $0.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try body(requests[0])["eventId"] as? String, try body(requests[1])["eventId"] as? String)
        XCTAssertEqual(groupStore.states[GroupTestFixtures.groupId]?.messages.count, 1)
    }

    @MainActor
    func testEventBeforeKeyIsKeptThenDecryptsWhenKeyArrives() async throws {
        let groupStore = store()
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        let peerId = "01ARZ3NDEKTSV4RRFFQ69G5B00"
        let epochTwoKey = SymmetricKey(size: .bits256)
        let cipher = try sealedText("late key", eventId: "01ARZ3NDEKTSV4RRFFQ69G5B01", author: peerId, epoch: 2, key: epochTwoKey)
        let wire = event(1, id: "01ARZ3NDEKTSV4RRFFQ69G5B01", author: peerId, epoch: 2, cipher: cipher)
        var hasKey = false
        var eventRequests = 0
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                return self.response(self.view(peers: [peerId], epoch: 2, seq: 1, hasKey: hasKey))
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" {
                eventRequests += 1
                return eventRequests == 1 ? self.eventsPage([wire]) : self.eventsPage([])
            }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await groupStore.sync(GroupTestFixtures.groupId)

        XCTAssertEqual(groupStore.states[GroupTestFixtures.groupId]?.pendingDecryptCount, 1)
        XCTAssertTrue(groupStore.states[GroupTestFixtures.groupId]?.messages.isEmpty == true)
        XCTAssertGreaterThan(eventRequests, 0)
        try secrets.saveRoomKey(epochTwoKey, for: GroupTestFixtures.groupId, epoch: 2)
        hasKey = true

        await groupStore.sync(GroupTestFixtures.groupId)

        XCTAssertEqual(groupStore.states[GroupTestFixtures.groupId]?.messages.map(\.text), ["late key"])
        XCTAssertEqual(groupStore.states[GroupTestFixtures.groupId]?.pendingDecryptCount, 0)
    }

    @MainActor
    func testForgedAndGarbledEventsAreSkipped() async throws {
        let groupStore = store()
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        let peerId = "01ARZ3NDEKTSV4RRFFQ69G5B00"
        let unknownId = "01ARZ3NDEKTSV4RRFFQ69G5B03"
        let ids = (1...6).map { "01ARZ3NDEKTSV4RRFFQ69G5B0\($0)" }
        let validOne = event(1, id: ids[0], author: peerId, cipher: try sealedText("before", eventId: ids[0], author: peerId))
        let unknown = event(2, id: ids[1], author: unknownId, cipher: try sealedText("unknown", eventId: ids[1], author: unknownId))
        let aadMismatch = event(3, id: ids[2], author: peerId, cipher: try sealedText("wrong aad", eventId: ids[2], author: peerId, aadEventId: ids[3]))
        let roomKey = try XCTUnwrap(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 1))
        let malformedCipher = try GroupCrypto.sealRaw(
            plaintext: Data("not json".utf8), key: roomKey,
            aad: GroupCrypto.messageAAD(groupId: GroupTestFixtures.groupId, memberId: peerId, eventId: ids[3], epoch: 1),
            nonce: AES.GCM.Nonce()
        ).base64EncodedString()
        let malformed = event(4, id: ids[3], author: peerId, cipher: malformedCipher)
        let oversizedData = try JSONEncoder().encode(GroupMessagePayload(kind: .text, text: String(repeating: "x", count: 4_001)))
        let oversizedCipher = try GroupCrypto.sealRaw(
            plaintext: oversizedData, key: roomKey,
            aad: GroupCrypto.messageAAD(groupId: GroupTestFixtures.groupId, memberId: peerId, eventId: ids[4], epoch: 1),
            nonce: AES.GCM.Nonce()
        ).base64EncodedString()
        let oversized = event(5, id: ids[4], author: peerId, cipher: oversizedCipher)
        let validTwo = event(6, id: ids[5], author: peerId, cipher: try sealedText("after", eventId: ids[5], author: peerId))
        let batch = [validOne, unknown, aadMismatch, malformed, oversized, validTwo]
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" { return self.response(self.view(peers: [peerId], seq: 6)) }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" { return self.eventsPage(batch) }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await groupStore.sync(GroupTestFixtures.groupId)

        XCTAssertEqual(groupStore.states[GroupTestFixtures.groupId]?.messages.map(\.text), ["before", "after"])
    }

    @MainActor
    func testGapSetsHasGap() async throws {
        let groupStore = store()
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" { return self.response(self.view(seq: 4, firstSeq: 5)) }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" { return self.eventsPage([], firstSeq: 5) }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await groupStore.sync(GroupTestFixtures.groupId)

        XCTAssertTrue(groupStore.states[GroupTestFixtures.groupId]?.hasGap == true)
    }

    @MainActor
    func testNotMemberMarksRemovedAndKeepsHistory() async throws {
        let groupStore = store()
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        let peerId = "01ARZ3NDEKTSV4RRFFQ69G5B00"
        let wire = event(1, id: "01ARZ3NDEKTSV4RRFFQ69G5B01", author: peerId, cipher: try sealedText("history", eventId: "01ARZ3NDEKTSV4RRFFQ69G5B01", author: peerId))
        var removed = false
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                return removed ? GroupTestFixtures.json("{\"error\":\"not_member\"}", status: 403) : self.response(self.view(peers: [peerId], seq: 1))
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" { return self.eventsPage([wire]) }
            return GroupTestFixtures.json("{}", status: 500)
        }
        await groupStore.sync(GroupTestFixtures.groupId)
        removed = true

        await groupStore.sync(GroupTestFixtures.groupId)

        XCTAssertEqual(groupStore.groups.first?.state, .removed)
        XCTAssertTrue(groupStore.states[GroupTestFixtures.groupId]?.supersededElsewhere == true)
        XCTAssertEqual(groupStore.states[GroupTestFixtures.groupId]?.messages.map(\.text), ["history"])
        XCTAssertNotNil(secrets.identity(for: GroupTestFixtures.groupId))
    }

    @MainActor
    func testTransientErrorDoesNotMarkRemoved() async throws {
        let groupStore = store()
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        var failure: GroupTestURLProtocol.Stub?
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                return failure ?? self.response(self.view())
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" { return self.eventsPage([]) }
            return GroupTestFixtures.json("{}", status: 500)
        }
        await groupStore.sync(GroupTestFixtures.groupId)

        for stub in [
            GroupTestFixtures.json("{}", status: 503),
            GroupTestFixtures.json("{\"error\":\"rate_limited\"}", status: 429),
            .init(status: 0, body: Data(), error: URLError(.notConnectedToInternet))
        ] {
            failure = stub
            await groupStore.sync(GroupTestFixtures.groupId)
            XCTAssertEqual(groupStore.groups.first?.state, .open)
            XCTAssertNotNil(secrets.identity(for: GroupTestFixtures.groupId))
        }
    }

    @MainActor
    func testBlockedMemberHiddenAndNotUnread() async throws {
        let secondGroupId = "01ARZ3NDEKTSV4RRFFQ69G5B10"
        let secondMemberId = "01ARZ3NDEKTSV4RRFFQ69G5B11"
        let groupStore = store(ids: [GroupTestFixtures.groupId, GroupTestFixtures.memberId, secondGroupId, secondMemberId])
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        try await createGroup(secondGroupId, in: groupStore)
        let peerId = "01ARZ3NDEKTSV4RRFFQ69G5B00"
        let firstEvent = event(1, id: "01ARZ3NDEKTSV4RRFFQ69G5B01", author: peerId, cipher: try sealedText("hidden", eventId: "01ARZ3NDEKTSV4RRFFQ69G5B01", author: peerId))
        let secondEvent = event(1, id: "01ARZ3NDEKTSV4RRFFQ69G5B02", author: peerId, cipher: try sealedText("visible", eventId: "01ARZ3NDEKTSV4RRFFQ69G5B02", author: peerId, groupId: secondGroupId))
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" { return self.response(self.view(peers: [peerId], seq: 1)) }
            if request.url?.path == "/v3/groups/\(secondGroupId)" { return self.response(self.view(groupId: secondGroupId, memberId: secondMemberId, peers: [peerId], seq: 1)) }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" { return self.eventsPage([firstEvent]) }
            if request.url?.path == "/v3/groups/\(secondGroupId)/events" { return self.eventsPage([secondEvent]) }
            return GroupTestFixtures.json("{}", status: 500)
        }
        groupStore.block(memberId: peerId, in: GroupTestFixtures.groupId)
        await groupStore.sync(GroupTestFixtures.groupId)
        await groupStore.sync(secondGroupId)

        XCTAssertTrue(groupStore.isBlocked(memberId: peerId, in: GroupTestFixtures.groupId))
        XCTAssertFalse(groupStore.isBlocked(memberId: peerId, in: secondGroupId))
        XCTAssertTrue(groupStore.states[GroupTestFixtures.groupId]?.messages.isEmpty == true)
        XCTAssertEqual(groupStore.groups.first(where: { $0.groupId == GroupTestFixtures.groupId })?.unread, 0)
        XCTAssertEqual(groupStore.states[secondGroupId]?.messages.map(\.text), ["visible"])
        let firstGroupDirectory = rootDirectory.appendingPathComponent(GroupTestFixtures.groupId)
        let entries = try FileManager.default.contentsOfDirectory(at: firstGroupDirectory, includingPropertiesForKeys: nil)
        let blockedData = try Data(contentsOf: firstGroupDirectory.appendingPathComponent("blocked-members.enc"))
        XCTAssertFalse(String(data: blockedData, encoding: .utf8)?.contains(peerId) == true)
        XCTAssertTrue(store().isBlocked(memberId: peerId, in: GroupTestFixtures.groupId))
        XCTAssertFalse(entries.contains { $0.lastPathComponent.lowercased().contains("tmp") })
        groupStore.unblock(memberId: peerId, in: GroupTestFixtures.groupId)
        XCTAssertFalse(groupStore.isBlocked(memberId: peerId, in: GroupTestFixtures.groupId))
    }

    @MainActor
    func testUnreadCountsOnlyOthersMessagesAfterMarkRead() async throws {
        let groupStore = store()
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        let peerId = "01ARZ3NDEKTSV4RRFFQ69G5B00"
        let blockedId = "01ARZ3NDEKTSV4RRFFQ69G5B03"
        let ids = (1...7).map { "01ARZ3NDEKTSV4RRFFQ69G5B0\($0)" }
        let entries = [
            event(1, id: ids[0], author: GroupTestFixtures.memberId, cipher: try sealedText("mine", eventId: ids[0], author: GroupTestFixtures.memberId)),
            event(2, id: ids[1], author: peerId, cipher: try sealedText("other", eventId: ids[1], author: peerId)),
            event(3, id: ids[2], author: blockedId, cipher: try sealedText("blocked", eventId: ids[2], author: blockedId)),
            event(4, id: ids[3], author: peerId, cipher: try sealedText("other again", eventId: ids[3], author: peerId))
        ]
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" { return self.response(self.view(peers: [peerId, blockedId], seq: 4)) }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" { return self.eventsPage(entries) }
            return GroupTestFixtures.json("{}", status: 500)
        }
        groupStore.block(memberId: blockedId, in: GroupTestFixtures.groupId)
        await groupStore.sync(GroupTestFixtures.groupId)
        XCTAssertEqual(groupStore.groups.first?.unread, 2)

        groupStore.markRead(GroupTestFixtures.groupId)
        groupStore.ingest([
            event(5, id: ids[4], author: GroupTestFixtures.memberId, cipher: try sealedText("mine later", eventId: ids[4], author: GroupTestFixtures.memberId)),
            event(6, id: ids[5], author: peerId, cipher: try sealedText("new other", eventId: ids[5], author: peerId)),
            event(7, id: ids[6], author: blockedId, cipher: try sealedText("new blocked", eventId: ids[6], author: blockedId))
        ], into: GroupTestFixtures.groupId)

        XCTAssertEqual(groupStore.groups.first?.unread, 1)
        XCTAssertEqual(groupStore.states[GroupTestFixtures.groupId]?.messages.map(\.text), ["mine", "other", "other again", "mine later", "new other"])
    }

    @MainActor
    func testSendRejectsEmptyAndOversizedWithoutRequest() async throws {
        let groupStore = store(ids: [GroupTestFixtures.groupId, GroupTestFixtures.memberId, "01ARZ3NDEKTSV4RRFFQ69G5B00"])
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        GroupTestURLProtocol.handler = { _ in GroupTestFixtures.json("{}", status: 500) }
        let requestCount = GroupTestURLProtocol.requests.count

        for text in [" \n\t", String(repeating: "漢", count: 3_000), String(repeating: "x", count: 4_001)] {
            do {
                try await groupStore.send(GroupTestFixtures.groupId, text: text)
                XCTFail("expected local message rejection")
            } catch {
                XCTAssertEqual(error as? GroupError, .tooLarge)
            }
        }

        XCTAssertEqual(GroupTestURLProtocol.requests.count, requestCount)
    }

    @MainActor
    func testSendWhenAwaitingKeyThrowsAndSendsNothing() async throws {
        let groupStore = store(ids: [GroupTestFixtures.groupId, GroupTestFixtures.memberId, "01ARZ3NDEKTSV4RRFFQ69G5B00"])
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        try setAwaitingKey(GroupTestFixtures.groupId)
        let requestCount = GroupTestURLProtocol.requests.count

        do {
            try await groupStore.send(GroupTestFixtures.groupId, text: "hello")
            XCTFail("expected awaiting key")
        } catch {
            XCTAssertEqual(error as? GroupError, .awaitingKey)
        }

        XCTAssertEqual(GroupTestURLProtocol.requests.count, requestCount)
    }

    @MainActor
    func testStaleEpochResyncsOnceThenResends() async throws {
        let groupStore = store(ids: [GroupTestFixtures.groupId, GroupTestFixtures.memberId, "01ARZ3NDEKTSV4RRFFQ69G5B00"])
        try await createGroup(GroupTestFixtures.groupId, in: groupStore)
        let epochTwoKey = SymmetricKey(size: .bits256)
        try secrets.saveRoomKey(epochTwoKey, for: GroupTestFixtures.groupId, epoch: 2)
        var postCount = 0
        var viewCount = 0
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events", request.httpMethod == "POST" {
                postCount += 1
                return postCount == 1 ? GroupTestFixtures.json("{\"error\":\"stale_epoch\"}", status: 409) : GroupTestFixtures.json("{\"seq\":1}")
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                viewCount += 1
                return self.response(self.view(epoch: 2))
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" { return self.eventsPage([]) }
            return GroupTestFixtures.json("{}", status: 500)
        }

        try await groupStore.send(GroupTestFixtures.groupId, text: "retry")

        let posts = GroupTestURLProtocol.requests.filter { $0.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" && $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(try body(posts[0])["epoch"] as? Int, 1)
        XCTAssertEqual(try body(posts[1])["epoch"] as? Int, 2)
        XCTAssertEqual(viewCount, 1)
        XCTAssertEqual(groupStore.states[GroupTestFixtures.groupId]?.messages.map(\.text), ["retry"])
    }
}
