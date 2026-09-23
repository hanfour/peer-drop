import XCTest
import CryptoKit
import PeerDropSecurity
import PeerDropAccount
@testable import PeerDropNotes
@testable import PeerDropDiary

@MainActor
final class DiaryStoreTests: XCTestCase {
    private var store: DiaryStore!
    private var dir: URL!
    private var keyStore: DiaryKeyStore!
    private var encryptor: ChatDataEncryptor!
    private let myAccountId = AccountID(raw: "0WNER001")!

    override func setUp() {
        TestURLProtocol.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("diary-store-\(UUID().uuidString)", isDirectory: true)
        encryptor = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))
        keyStore = DiaryKeyStore(directory: dir, encryptor: encryptor)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TestURLProtocol.self]
        let account = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg), authProvider: { _ in }, tokenInvalidator: {})
        let manager = AccountManager(mock: Account(accountId: myAccountId, nickname: "owner", mailboxId: "mbx", createdAt: Date()))
        store = DiaryStore(client: DiaryClient(account: account), notesClient: NotesClient(account: account), accountManager: manager,
                           crypto: DiaryFakeCrypto(), keyStore: keyStore, directory: dir, encryptor: encryptor, directoryCache: DirectoryCache())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private func body(_ i: Int) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: TestURLProtocol.requests[i].httpBody ?? Data()) as! [String: Any]
    }

    /// A syntactically-valid diary id, mirroring `DiaryClientTests.did(_:)`
    /// — needed for `join`/`sync`/`acceptRelayedKey` tests, which take a
    /// caller-supplied id (unlike `create`, which mints its own real ULID).
    private func did(_ label: String) -> String {
        precondition(label.count <= 26)
        // Crockford base32, minus I/L/O/U — same shape `DiaryClient`'s own
        // path validation requires. Catches an easy mistake (a descriptive
        // label that happens to contain one of those letters) as a loud
        // test-setup failure instead of a silent `.badId` inside `sync`/
        // `handlePush`, which swallow it into `lastError` and make the
        // failure look like "zero requests happened" instead.
        precondition(label.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }, "'\(label)' isn't a valid diary-id label")
        return label + String(repeating: "0", count: 26 - label.count)
    }

    private func membersJSON(_ members: [String]) -> String {
        "[" + members.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// `DiaryKeyDisposition` has no `Equatable` conformance upstream — this
    /// compares by pattern match instead of `XCTAssertEqual`.
    private func assertDisposition(_ actual: DiaryKeyDisposition, _ expected: DiaryKeyDisposition, file: StaticString = #filePath, line: UInt = #line) {
        switch (actual, expected) {
        case (.installed, .installed), (.rejected, .rejected), (.transient, .transient):
            return
        default:
            XCTFail("expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    /// Creates a diary via the public API (stubbing only the `POST
    /// /v3/diaries` response) — `create()` ignores the response's echoed
    /// `diaryId` for local storage (see `DiaryStore.create`'s doc), so the
    /// response body's id doesn't need to match anything real.
    @discardableResult
    private func createDiary(name: String = "My Diary") async throws -> String {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"diaryId":"IGNORED00000000000000000A","inviteCode":"CODE0001"}"#.utf8))]
        return try await store.create(name: name)
    }

    /// Seeds a diary as locally-known (meta + members persisted) via the
    /// public `join(code:)` path, without ever attempting a key install —
    /// exactly the state a short-code join leaves behind, and a convenient
    /// way to get `acceptRelayedKey` a diary to work against without
    /// reaching into `DiaryStore`'s private disk layout.
    private func seedKnownDiary(diaryId: String, members: [String], metaKey: SymmetricKey?, name: String = "Diary") async throws {
        let metaCipher: String
        if let metaKey {
            metaCipher = try DiaryCrypto.sealMeta(name: name, key: metaKey, diaryId: diaryId, keyEpoch: 1).base64EncodedString()
        } else {
            metaCipher = "bWV0YQ=="
        }
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"""
        {"diaryId":"\#(diaryId)","members":\#(membersJSON(members)),"holderIndex":0,"ownerAccountId":"\#(members[0])","state":"open","seq":0,"metaCipher":"\#(metaCipher)"}
        """#.utf8))]
        _ = try await store.join(code: "SEEDCODE")
    }

    private func relayPlaintext(diaryId: String, key: SymmetricKey, senderAccountId: String, keyEpoch: Int = 1) throws -> NotePlaintext {
        let dict: [String: Any] = ["diaryId": diaryId, "keyEpoch": keyEpoch, "key": key.withUnsafeBytes { Data($0) }.base64EncodedString()]
        let json = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return NotePlaintext(kind: .diaryKey, text: String(decoding: json, as: UTF8.self), sentAt: Int64(Date().timeIntervalSince1970), sender: nil)
    }

    private func base64URL(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: - init(mock:states:) touches no network/disk

    func testMockInitTouchesNoNetworkOrDisk() {
        let meta = DiaryMeta(diaryId: "D1", ownerAccountId: "A1", members: ["A1", "A2"], holderIndex: 0, seq: 0, state: "open", keyEpoch: 1, metaCipher: "bWV0YQ==")
        let state = DiaryState(meta: meta, events: [], isHolder: true, isOwner: true, hasKey: true, pendingKey: false)
        let summary = DiarySummary(diaryId: "D1", name: "Test", memberCount: 2, holderAccountId: "A1", isMyTurn: true)

        let mockStore = DiaryStore(mock: [summary], states: ["D1": state])

        XCTAssertEqual(mockStore.diaries, [summary])
        XCTAssertEqual(mockStore.states["D1"], state)
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    // MARK: - create: key.enc before POST, same-id resend after a transient failure

    func testCreateWritesKeyBeforePostingAndResendsSameIdAfterATransientFailure() async throws {
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        do {
            _ = try await store.create(name: "My Diary")
            XCTFail("expected a transient error")
        } catch {
            XCTAssertEqual(error as? DiaryError, .transient("http_500"))
        }
        XCTAssertEqual(TestURLProtocol.requests.count, 1)
        let firstDiaryId = body(0)["diaryId"] as! String
        // key.enc already exists — it was written BEFORE the (failed) POST.
        XCTAssertNotNil(keyStore.key(for: firstDiaryId))

        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"diaryId":"IGNORED00000000000000000B","inviteCode":"CODE9999"}"#.utf8))]
        let diaryId = try await store.create(name: "My Diary")

        XCTAssertEqual(diaryId, firstDiaryId)                       // SAME id resent
        XCTAssertEqual(body(1)["diaryId"] as? String, firstDiaryId)
        let state = try XCTUnwrap(store.states[diaryId])
        XCTAssertTrue(state.hasKey)
        XCTAssertTrue(state.isOwner)
        XCTAssertTrue(state.isHolder)
        XCTAssertEqual(state.meta.inviteCode, "CODE9999")
    }

    func testCreateOn409ExistsClearsPendingAndDoesNotResendTheSameId() async throws {
        TestURLProtocol.queue = [.init(status: 409, body: Data(#"{"error":"diary_exists"}"#.utf8))]
        do {
            _ = try await store.create(name: "Clash")
            XCTFail("expected .exists")
        } catch {
            XCTAssertEqual(error as? DiaryError, .exists)
        }
        let firstDiaryId = body(0)["diaryId"] as! String

        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"diaryId":"IGNORED00000000000000000C","inviteCode":"CODE0002"}"#.utf8))]
        let secondDiaryId = try await store.create(name: "Clash")
        XCTAssertNotEqual(secondDiaryId, firstDiaryId)   // a fresh id, not a resend
    }

    // MARK: - join(link:): meta persisted before key validated; wrong key → pendingKey

    func testJoinByLinkPersistsMetaAndLeavesPendingKeyWhenTheKeyIsWrong() async throws {
        let diaryId = did("JNBADKY1")
        let ownerKey = SymmetricKey(size: .bits256)
        let metaCipher = try DiaryCrypto.sealMeta(name: "Shared Diary", key: ownerKey, diaryId: diaryId, keyEpoch: 1).base64EncodedString()
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"""
        {"diaryId":"\#(diaryId)","members":["0WNER001","NEWACCT1"],"holderIndex":0,"ownerAccountId":"0WNER001","state":"open","seq":0,"metaCipher":"\#(metaCipher)"}
        """#.utf8))]

        let wrongKey = SymmetricKey(size: .bits256)
        let link = URL(string: "peerdrop://diary/\(diaryId)?code=CODE1234#k=\(base64URL(wrongKey))")!

        let returned = try await store.join(link: link)
        XCTAssertEqual(returned, diaryId)

        // meta + members ARE persisted despite the key being wrong.
        let state = try XCTUnwrap(store.states[diaryId])
        XCTAssertEqual(state.meta.members, ["0WNER001", "NEWACCT1"])
        XCTAssertFalse(state.hasKey)
        XCTAssertTrue(state.pendingKey)
        XCTAssertNil(keyStore.key(for: diaryId))
    }

    func testJoinByLinkWithTheCorrectKeyInstallsItAndDecodesTheName() async throws {
        let diaryId = did("JNKEYYES1")
        let key = SymmetricKey(size: .bits256)
        let metaCipher = try DiaryCrypto.sealMeta(name: "Shared Diary", key: key, diaryId: diaryId, keyEpoch: 1).base64EncodedString()
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"""
        {"diaryId":"\#(diaryId)","members":["0WNER001","NEWACCT1"],"holderIndex":0,"ownerAccountId":"0WNER001","state":"open","seq":0,"metaCipher":"\#(metaCipher)"}
        """#.utf8))]
        let link = URL(string: "peerdrop://diary/\(diaryId)?code=CODE1234#k=\(base64URL(key))")!

        _ = try await store.join(link: link)

        let state = try XCTUnwrap(store.states[diaryId])
        XCTAssertTrue(state.hasKey)
        XCTAssertFalse(state.pendingKey)
        XCTAssertEqual(state.meta.name, "Shared Diary")
        XCTAssertNotNil(keyStore.key(for: diaryId))
    }

    func testJoinByLinkWithAMalformedLinkThrowsBeforeAnyRequest() async {
        do {
            _ = try await store.join(link: URL(string: "peerdrop://notdiary/\(did("X"))?code=C#k=AAAA")!)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DiaryError, .badId)
        }
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    // MARK: - join(code:): always leaves pendingKey

    func testJoinByCodeLeavesPendingKeyWithNoKeyAttempt() async throws {
        let diaryId = did("JNCD1")
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"""
        {"diaryId":"\#(diaryId)","members":["0WNER001","NEWACCT1"],"holderIndex":0,"ownerAccountId":"0WNER001","state":"open","seq":0,"metaCipher":"bWV0YQ=="}
        """#.utf8))]
        let returned = try await store.join(code: "SHORT001")

        XCTAssertEqual(returned, diaryId)
        let state = try XCTUnwrap(store.states[diaryId])
        XCTAssertTrue(state.pendingKey)
        XCTAssertFalse(state.hasKey)
        XCTAssertNil(keyStore.key(for: diaryId))
    }

    // MARK: - sync: GET meta overwrites holderIndex; events upsert without duplication

    func testSyncOverwritesHolderIndexFromMetaAndUpsertsEventsWithoutDuplication() async throws {
        let diaryId = did("SYNCTEST1")
        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001","M2"],"holderIndex":1,"seq":2,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
            """#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[
              {"seq":1,"eventId":"E1","type":"entry","authorAccountId":"0WNER001","payloadCipher":"cGF5","createdAt":1700000000000},
              {"seq":2,"eventId":"E2","type":"pass","authorAccountId":"0WNER001","createdAt":1700000001000}
            ]}
            """#.utf8)),
        ]
        await store.sync(diaryId)
        let state = try XCTUnwrap(store.states[diaryId])
        XCTAssertEqual(state.meta.holderIndex, 1)
        XCTAssertEqual(state.meta.seq, 2)
        XCTAssertEqual(state.events.map(\.seq), [1, 2])
        XCTAssertEqual(TestURLProtocol.requests[1].url?.query, "since=0&limit=100")

        // Second sync: the server reports the same turn state and no new
        // events — the local event list must not grow or duplicate.
        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001","M2"],"holderIndex":1,"seq":2,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
            """#.utf8)),
            .init(status: 200, body: Data(#"{"events":[]}"#.utf8)),
        ]
        await store.sync(diaryId)
        let state2 = try XCTUnwrap(store.states[diaryId])
        XCTAssertEqual(state2.events.map(\.seq), [1, 2])
        XCTAssertEqual(TestURLProtocol.requests[3].url?.query, "since=2&limit=100")
    }

    func testSyncTriggersKeyRelayForAnUnrelayedJoinEvent() async throws {
        let diaryId = did("SYNCRY1")
        let key = SymmetricKey(size: .bits256)
        try keyStore.save(key: key, for: diaryId)
        let metaCipher = try DiaryCrypto.sealMeta(name: "Diary", key: key, diaryId: diaryId, keyEpoch: 1).base64EncodedString()
        let newMember = try DiaryRecipientFixture()

        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001","\#(newMember.accountId.raw)"],"holderIndex":0,"seq":1,"state":"open","keyEpoch":1,"metaCipher":"\#(metaCipher)"}
            """#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":1,"eventId":"JOINEVT1","type":"join","authorAccountId":"\#(newMember.accountId.raw)","createdAt":1700000000000}]}
            """#.utf8)),
            .init(status: 200, body: try newMember.directoryJSON()),
            .init(status: 200, body: Data(#"{"challenge":"Q0hBTA=="}"#.utf8)),
            .init(status: 201, body: Data(#"{"id":"01SENT0000000000000000000B"}"#.utf8)),
        ]
        await store.sync(diaryId)

        XCTAssertEqual(TestURLProtocol.requests.count, 5)
        XCTAssertEqual(TestURLProtocol.requests[2].url?.path, "/v3/directory/\(newMember.accountId.raw)")
        XCTAssertEqual(TestURLProtocol.requests[4].url?.path, "/v3/notes/\(newMember.accountId.raw)")
        XCTAssertEqual(body(4)["kind"] as? String, "diaryKey")
    }

    // MARK: - writeEntry: pending → POST → GET event; local event comes from the server

    func testWriteEntryPendingThenPostsThenFetchesTheCanonicalEventFromTheServer() async throws {
        let diaryId = try await createDiary()
        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"seq":1,"holderIndex":0}"#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":1,"eventId":"SERVERWON","type":"entry","authorAccountId":"0WNER001","payloadCipher":"c2VydmVyLWNpcGhlcg==","createdAt":1700000000000}]}
            """#.utf8)),
        ]
        try await store.writeEntry(diaryId, text: "Dear diary...")

        // The POST used a CLIENT-generated eventId...
        let postedEventId = body(TestURLProtocol.requests.count - 2)["eventId"] as! String
        XCTAssertNotEqual(postedEventId, "SERVERWON")
        // ...but the local event is exactly what the server returned from
        // `event(id:seq:)` — never synthesized from the write call.
        let state = try XCTUnwrap(store.states[diaryId])
        XCTAssertEqual(state.events.map(\.eventId), ["SERVERWON"])
        XCTAssertEqual(state.events[0].payloadCipher, "c2VydmVyLWNpcGhlcg==")
    }

    func testWriteEntryWithoutAKeyThrowsNoKey() async throws {
        let diaryId = did("NKEYWRT1")
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"""
        {"diaryId":"\#(diaryId)","members":["0WNER001"],"holderIndex":0,"ownerAccountId":"0WNER001","state":"open","seq":0,"metaCipher":"bWV0YQ=="}
        """#.utf8))]
        _ = try await store.join(code: "NOKEY0001")   // pendingKey — no key.enc

        do {
            try await store.writeEntry(diaryId, text: "x")
            XCTFail("expected .noKey")
        } catch {
            XCTAssertEqual(error as? DiaryError, .noKey)
        }
    }

    // MARK: - pass

    func testPassPostsAndPicksUpTheNewHolderIndex() async throws {
        let diaryId = try await createDiary()
        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"seq":1,"holderIndex":1}"#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":1,"eventId":"E1","type":"pass","authorAccountId":"0WNER001","createdAt":1700000000000}]}
            """#.utf8)),
        ]
        try await store.pass(diaryId)
        let state = try XCTUnwrap(store.states[diaryId])
        XCTAssertEqual(state.meta.holderIndex, 1)
        XCTAssertEqual(state.events.map(\.type), [.pass])
        XCTAssertEqual(body(TestURLProtocol.requests.count - 2)["type"] as? String, "pass")
    }

    // MARK: - comment / like

    func testCommentAndLikeIncludeRefSeqAndPersistBothEvents() async throws {
        let diaryId = try await createDiary()

        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"seq":1,"holderIndex":0}"#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":1,"eventId":"C1","type":"comment","authorAccountId":"0WNER001","refSeq":0,"payloadCipher":"Y2lwaGVy","createdAt":1700000000000}]}
            """#.utf8)),
        ]
        try await store.comment(diaryId, seq: 0, text: "nice entry!")
        XCTAssertEqual(body(TestURLProtocol.requests.count - 2)["refSeq"] as? Int, 0)
        XCTAssertEqual(body(TestURLProtocol.requests.count - 2)["type"] as? String, "comment")

        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"seq":2,"holderIndex":0}"#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":2,"eventId":"L1","type":"like","authorAccountId":"0WNER001","refSeq":0,"createdAt":1700000001000}]}
            """#.utf8)),
        ]
        try await store.like(diaryId, seq: 0)
        XCTAssertEqual(body(TestURLProtocol.requests.count - 2)["refSeq"] as? Int, 0)
        XCTAssertNil(body(TestURLProtocol.requests.count - 2)["payloadCipher"])

        let state = try XCTUnwrap(store.states[diaryId])
        XCTAssertEqual(state.events.map(\.type), [.comment, .like])
    }

    // MARK: - pending: 403 clears it, .transient keeps it (same eventId resent)

    func testTransientFailureKeepsPendingAndResendsTheSameEventId() async throws {
        let diaryId = try await createDiary()

        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        do {
            try await store.pass(diaryId)
            XCTFail("expected .transient")
        } catch {
            XCTAssertEqual(error as? DiaryError, .transient("http_500"))
        }
        let firstEventId = body(TestURLProtocol.requests.count - 1)["eventId"] as! String

        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"seq":1,"holderIndex":1}"#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":1,"eventId":"WHATEVER","type":"pass","authorAccountId":"0WNER001","createdAt":1700000000000}]}
            """#.utf8)),
        ]
        try await store.pass(diaryId)
        let secondAttemptEventId = body(TestURLProtocol.requests.count - 2)["eventId"] as! String
        XCTAssertEqual(secondAttemptEventId, firstEventId)
    }

    func testAHardFailureClearsPendingAndTheNextAttemptUsesAFreshEventId() async throws {
        let diaryId = try await createDiary()

        TestURLProtocol.queue = [.init(status: 403, body: Data(#"{"error":"not_holder"}"#.utf8))]
        do {
            try await store.pass(diaryId)
            XCTFail("expected .notHolder")
        } catch {
            XCTAssertEqual(error as? DiaryError, .notHolder)
        }
        let firstEventId = body(TestURLProtocol.requests.count - 1)["eventId"] as! String

        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"seq":1,"holderIndex":1}"#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":1,"eventId":"X","type":"pass","authorAccountId":"0WNER001","createdAt":1700000000000}]}
            """#.utf8)),
        ]
        try await store.pass(diaryId)
        let secondEventId = body(TestURLProtocol.requests.count - 2)["eventId"] as! String
        XCTAssertNotEqual(secondEventId, firstEventId)
    }

    // MARK: - acceptRelayedKey: the three dispositions

    func testAcceptRelayedKeyIsTransientWhenDiaryIsNotKnownLocally() async throws {
        let diaryId = did("XKNDRY1")
        let plaintext = try relayPlaintext(diaryId: diaryId, key: SymmetricKey(size: .bits256), senderAccountId: "0WNER001")
        let disposition = await store.acceptRelayedKey(plaintext, sender: .verified(accountId: "0WNER001", nickname: nil))
        assertDisposition(disposition, .transient)
    }

    func testAcceptRelayedKeyIsRejectedWhenSenderIsNotAMember() async throws {
        let diaryId = did("REJCTST1")
        try await seedKnownDiary(diaryId: diaryId, members: ["0WNER001", "MEMBER02"], metaKey: nil)
        let plaintext = try relayPlaintext(diaryId: diaryId, key: SymmetricKey(size: .bits256), senderAccountId: "STRANGER1")
        let disposition = await store.acceptRelayedKey(plaintext, sender: .verified(accountId: "STRANGER1", nickname: nil))
        assertDisposition(disposition, .rejected)
        XCTAssertNil(keyStore.key(for: diaryId))
    }

    func testAcceptRelayedKeyIsRejectedForAnAnonymousSenderEvenWhenTheDiaryIsKnown() async throws {
        let diaryId = did("ANNREJCT1")
        let key = SymmetricKey(size: .bits256)
        try await seedKnownDiary(diaryId: diaryId, members: ["0WNER001"], metaKey: key)
        let plaintext = try relayPlaintext(diaryId: diaryId, key: key, senderAccountId: "0WNER001")
        let disposition = await store.acceptRelayedKey(plaintext, sender: .anonymous)
        assertDisposition(disposition, .rejected)
        XCTAssertNil(keyStore.key(for: diaryId))
    }

    func testAcceptRelayedKeyIsRejectedForAnUnverifiedSender() async throws {
        let diaryId = did("NVRFYD1")
        let key = SymmetricKey(size: .bits256)
        try await seedKnownDiary(diaryId: diaryId, members: ["0WNER001"], metaKey: key)
        let plaintext = try relayPlaintext(diaryId: diaryId, key: key, senderAccountId: "0WNER001")
        let disposition = await store.acceptRelayedKey(plaintext, sender: .unverified(accountId: "0WNER001"))
        assertDisposition(disposition, .rejected)
        XCTAssertNil(keyStore.key(for: diaryId))
    }

    func testAcceptRelayedKeyIsRejectedForMalformedJSON() async throws {
        let diaryId = did("MFRMD1")
        let key = SymmetricKey(size: .bits256)
        try await seedKnownDiary(diaryId: diaryId, members: ["0WNER001"], metaKey: key)
        let plaintext = NotePlaintext(kind: .diaryKey, text: "not json", sentAt: Int64(Date().timeIntervalSince1970), sender: nil)
        let disposition = await store.acceptRelayedKey(plaintext, sender: .verified(accountId: "0WNER001", nickname: nil))
        assertDisposition(disposition, .rejected)
    }

    func testAcceptRelayedKeyInstallsWhenSenderIsAVerifiedMemberAndTheKeyOpensMetaCipher() async throws {
        let diaryId = did("STAKYES1")
        let realKey = SymmetricKey(size: .bits256)
        try await seedKnownDiary(diaryId: diaryId, members: ["0WNER001", "MEMBER02"], metaKey: realKey, name: "Our Diary")
        let plaintext = try relayPlaintext(diaryId: diaryId, key: realKey, senderAccountId: "0WNER001")

        let disposition = await store.acceptRelayedKey(plaintext, sender: .verified(accountId: "0WNER001", nickname: "owner"))

        assertDisposition(disposition, .installed)
        XCTAssertNotNil(keyStore.key(for: diaryId))
        let state = try XCTUnwrap(store.states[diaryId])
        XCTAssertTrue(state.hasKey)
        XCTAssertFalse(state.pendingKey)
        XCTAssertEqual(state.meta.name, "Our Diary")
    }

    // MARK: - handlePush("diaryKeyRequest"): syncs and force-relays

    func testHandlePushDiaryKeyRequestSyncsAndForceRelays() async throws {
        let diaryId = did("PSHFRC1")
        let key = SymmetricKey(size: .bits256)
        try keyStore.save(key: key, for: diaryId)
        let metaCipher = try DiaryCrypto.sealMeta(name: "Diary", key: key, diaryId: diaryId, keyEpoch: 1).base64EncodedString()
        let newMember = try DiaryRecipientFixture()

        // `handlePush` always calls `sync(_:)` first, which ITSELF already
        // relays to every un-relayed `join` event it sees (force: false) —
        // then, because this push is `diaryKeyRequest`, it relays AGAIN
        // (force: true), bypassing the dedupe the first attempt just wrote.
        // Both attempts run the full lookup → PoW → send sequence, so two
        // full sets of stubs are needed.
        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001","\#(newMember.accountId.raw)"],"holderIndex":0,"seq":1,"state":"open","keyEpoch":1,"metaCipher":"\#(metaCipher)"}
            """#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":1,"eventId":"JOINEVT2","type":"join","authorAccountId":"\#(newMember.accountId.raw)","createdAt":1700000000000}]}
            """#.utf8)),
            .init(status: 200, body: try newMember.directoryJSON()),
            .init(status: 200, body: Data(#"{"challenge":"Q0hBTA=="}"#.utf8)),
            .init(status: 201, body: Data(#"{"id":"01SENT0000000000000000000C"}"#.utf8)),
            .init(status: 200, body: try newMember.directoryJSON()),
            .init(status: 200, body: Data(#"{"challenge":"Q0hBTA=="}"#.utf8)),
            .init(status: 201, body: Data(#"{"id":"01SENT0000000000000000000D"}"#.utf8)),
        ]
        await store.handlePush(kind: "diaryKeyRequest", diaryId: diaryId)

        XCTAssertEqual(TestURLProtocol.requests.count, 8)
        XCTAssertEqual(TestURLProtocol.requests.last?.url?.path, "/v3/notes/\(newMember.accountId.raw)")
        XCTAssertEqual(TestURLProtocol.requests.filter { $0.url?.path == "/v3/notes/\(newMember.accountId.raw)" }.count, 2)
    }
}
