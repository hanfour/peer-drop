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

    /// `DiaryStore.PendingEvent` is private to `DiaryStore.swift` — this is
    /// a structurally-identical decode target so tests can read
    /// `pending.enc` directly off disk (review round 1, minor: tests that
    /// actually inspect the file, not just infer its contents indirectly
    /// via a resend).
    private struct DirectPendingEvent: Codable, Equatable { let eventId: String; let type: DiaryEventType; let refSeq: Int?; let payloadCipher: String? }

    private func readPendingEventDirectly(_ diaryId: String) -> DirectPendingEvent? {
        let url = dir.appendingPathComponent(diaryId, isDirectory: true).appendingPathComponent("pending.enc")
        guard let data = try? encryptor.readAndDecrypt(from: url) else { return nil }
        return try? JSONDecoder().decode(DirectPendingEvent.self, from: data)
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

    // MARK: - pending: a stuck pending event is resolved FIRST, never silently swallowed (review round 1, C1)

    /// A stuck pending `pass` is resent as its OWN complete POST + fetch
    /// BEFORE the caller's actual request (a new `writeEntry`) is even
    /// sealed — two independent POSTs, in order, and the entry's text is
    /// genuinely what got sealed and sent (the pre-fix bug silently
    /// dropped it while reporting success for the stale `pass` instead).
    func testPendingPassPlusNewEntryPostsBothInOrderAndSealsTheEntrysOwnText() async throws {
        let diaryId = try await createDiary()

        // Get a `pass` stuck in `pending.enc` via a transient failure.
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        do {
            try await store.pass(diaryId)
            XCTFail("expected .transient")
        } catch {
            XCTAssertEqual(error as? DiaryError, .transient("http_500"))
        }
        let stuckEventId = body(TestURLProtocol.requests.count - 1)["eventId"] as! String

        // Now request something ELSE entirely — writeEntry.
        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"seq":1,"holderIndex":0}"#.utf8)),   // resend of the stuck pass
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":1,"eventId":"PASSLANDED","type":"pass","authorAccountId":"0WNER001","createdAt":1700000000000}]}
            """#.utf8)),
            .init(status: 201, body: Data(#"{"seq":2,"holderIndex":0}"#.utf8)),   // the NEW entry
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":2,"eventId":"ENTRYLANDED","type":"entry","authorAccountId":"0WNER001","payloadCipher":"REPLACED","createdAt":1700000001000}]}
            """#.utf8)),
        ]
        try await store.writeEntry(diaryId, text: "hello from the new write")

        // Requests, in order: create POST, failed pass POST(500), pass
        // resend POST, pass GET-event (no body), entry POST, entry
        // GET-event (no body) — 6 total. `body(_:)` can't be called on a
        // GET (empty httpBody), so index the two POSTs by their position
        // relative to the end.
        XCTAssertEqual(TestURLProtocol.requests.count, 6)
        let passResendPostIndex = TestURLProtocol.requests.count - 4
        let entryPostIndex = TestURLProtocol.requests.count - 2
        XCTAssertEqual(TestURLProtocol.requests[passResendPostIndex].httpMethod, "POST")
        XCTAssertEqual(TestURLProtocol.requests[entryPostIndex].httpMethod, "POST")

        let firstPostType = body(passResendPostIndex)["type"] as? String
        let firstPostEventId = body(passResendPostIndex)["eventId"] as? String
        let secondPostType = body(entryPostIndex)["type"] as? String
        XCTAssertEqual(firstPostType, "pass")
        XCTAssertEqual(firstPostEventId, stuckEventId)   // the STUCK pass, resent unchanged
        XCTAssertEqual(secondPostType, "entry")

        // The entry's OWN text was genuinely sealed for the NEW eventId —
        // not skipped, not the stuck pass's payload.
        let entryPayloadCipher = body(entryPostIndex)["payloadCipher"] as! String
        let key = try XCTUnwrap(keyStore.key(for: diaryId))
        let sealedData = try XCTUnwrap(Data(base64Encoded: entryPayloadCipher))
        let sentEventId = body(entryPostIndex)["eventId"] as! String
        let opened = try DiaryCrypto.open(sealedData, key: key, diaryId: diaryId, authorAccountId: myAccountId.raw, eventId: sentEventId, maxScalars: DiaryCrypto.maxEntryScalars)
        XCTAssertEqual(opened.text, "hello from the new write")

        let state = try XCTUnwrap(store.states[diaryId])
        XCTAssertEqual(Set(state.events.map(\.eventId)), Set(["PASSLANDED", "ENTRYLANDED"]))
    }

    /// If the stuck pending event is STILL `.transient` on resend, the new
    /// write never happens at all — the caller's new text is never
    /// sealed/sent (it's simply never attempted), and `pending.enc` still
    /// holds the ORIGINAL stuck event, untouched.
    func testPendingStillTransientThrowsAndLeavesTheOriginalPendingEventInPlace() async throws {
        let diaryId = try await createDiary()

        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        do {
            try await store.pass(diaryId)
            XCTFail("expected .transient")
        } catch {
            XCTAssertEqual(error as? DiaryError, .transient("http_500"))
        }
        let stuckEventId = body(TestURLProtocol.requests.count - 1)["eventId"] as! String

        // The resend ALSO fails transiently.
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        do {
            try await store.writeEntry(diaryId, text: "this must never be sent")
            XCTFail("expected .transient(\"pending\")")
        } catch {
            XCTAssertEqual(error as? DiaryError, .transient("pending"))
        }
        // Only the ONE resend attempt happened (create + the original
        // failed pass + this one resend = 3) — the new entry was never
        // even sealed/POSTed.
        XCTAssertEqual(TestURLProtocol.requests.count, 3)

        let stillPending = try XCTUnwrap(readPendingEventDirectly(diaryId))
        XCTAssertEqual(stillPending.eventId, stuckEventId)
        XCTAssertEqual(stillPending.type, .pass)
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

    /// Review round 3: with NO `accountId`, `handlePush("diaryKeyRequest")`
    /// is now just `sync(diaryId)` — the forced fan-out-to-every-join-event
    /// loop was dropped entirely (the worker always includes `accountId`
    /// on a real `diaryKeyRequest` push; a second, forced pass over events
    /// `sync`'s own un-forced pass just relayed to had no real payload and
    /// was what caused round 2's defect-3 double-send). `sync`'s OWN
    /// un-forced, deduped relay pass is what actually reaches the
    /// un-relayed `join` event's author here — exactly once.
    func testHandlePushDiaryKeyRequestWithNoAccountIdIsJustASync() async throws {
        let diaryId = did("PSHFRC1")
        let key = SymmetricKey(size: .bits256)
        try keyStore.save(key: key, for: diaryId)
        let metaCipher = try DiaryCrypto.sealMeta(name: "Diary", key: key, diaryId: diaryId, keyEpoch: 1).base64EncodedString()
        let newMember = try DiaryRecipientFixture()

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
        ]
        await store.handlePush(kind: "diaryKeyRequest", diaryId: diaryId)

        XCTAssertEqual(TestURLProtocol.requests.count, 5)
        XCTAssertEqual(TestURLProtocol.requests.last?.url?.path, "/v3/notes/\(newMember.accountId.raw)")
        XCTAssertEqual(TestURLProtocol.requests.filter { $0.url?.path == "/v3/notes/\(newMember.accountId.raw)" }.count, 1)
    }

    /// Review round 1, I4: an `accountId` on the push targets the relay at
    /// exactly that member, independent of `join` events entirely — here
    /// there are NONE (the old fan-out-over-join-events loop would do
    /// nothing), yet the targeted member still gets a relay attempt.
    /// Review round 2, defect 3 moved the targeted relay BEFORE `sync` — so
    /// this device now needs `meta.enc` ALREADY persisted (a realistic
    /// precondition: `handlePush` only ever fires for a diary this device
    /// already tracks) before the push arrives, not populated by `sync`
    /// itself partway through this same call.
    func testHandlePushDiaryKeyRequestWithAccountIdRelaysToThatMemberEvenWithoutAJoinEvent() async throws {
        let diaryId = did("PSHTGT1")
        let key = SymmetricKey(size: .bits256)
        let metaCipher = try DiaryCrypto.sealMeta(name: "Diary", key: key, diaryId: diaryId, keyEpoch: 1).base64EncodedString()
        let requester = "REQSTER1"

        // Seed: this device already tracks the diary but has no key yet —
        // its own fan-out is a guaranteed no-op either way.
        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001","\#(requester)"],"holderIndex":0,"seq":0,"state":"open","keyEpoch":1,"metaCipher":"\#(metaCipher)"}
            """#.utf8)),
            .init(status: 200, body: Data(#"{"events":[]}"#.utf8)),
        ]
        await store.sync(diaryId)
        try keyStore.save(key: key, for: diaryId)

        // Stub order now matches the NEW call order: the targeted relay's
        // directory lookup fires FIRST, THEN `sync`'s own GET meta/events.
        TestURLProtocol.queue = [
            .init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8)),   // GET /v3/directory/REQSTER1?bundle=1
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001","\#(requester)"],"holderIndex":0,"seq":0,"state":"open","keyEpoch":1,"metaCipher":"\#(metaCipher)"}
            """#.utf8)),
            .init(status: 200, body: Data(#"{"events":[]}"#.utf8)),   // no join events at all
        ]
        await store.handlePush(kind: "diaryKeyRequest", diaryId: diaryId, accountId: requester)

        XCTAssertEqual(TestURLProtocol.requests.count, 5)   // 2 (seed) + 3 (this push)
        // The FIRST request of the push's own work is the targeted relay's
        // directory lookup — it ran BEFORE `sync`'s own GET meta.
        XCTAssertEqual(TestURLProtocol.requests[2].url?.path, "/v3/directory/\(requester)")
    }

    /// Review round 2, defect 3: the SAME member the push names must never
    /// get relayed to twice — once from the targeted `force: true` call and
    /// again from `sync`'s own un-forced fan-out — when a `join` event for
    /// them is already known locally and no dedupe entry exists yet.
    func testHandlePushAccountIdSendsExactlyOnceWhenAJoinEventIsAlreadyKnownAndNoDedupeExists() async throws {
        let diaryId = did("PSHRD1")
        let requester = try DiaryRecipientFixture()
        let key = SymmetricKey(size: .bits256)
        let metaCipher = try DiaryCrypto.sealMeta(name: "Diary", key: key, diaryId: diaryId, keyEpoch: 1).base64EncodedString()

        // Seed: a `join` event for the requester is already known locally,
        // but this device has NO key yet — nothing gets relayed/deduped.
        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001","\#(requester.accountId.raw)"],"holderIndex":0,"seq":1,"state":"open","keyEpoch":1,"metaCipher":"\#(metaCipher)"}
            """#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":1,"eventId":"JOINSEED1","type":"join","authorAccountId":"\#(requester.accountId.raw)","createdAt":1700000000000}]}
            """#.utf8)),
        ]
        await store.sync(diaryId)
        XCTAssertEqual(TestURLProtocol.requests.count, 2)

        // The key arrives (e.g. via `acceptRelayedKey` elsewhere) — no
        // dedupe entry exists for this member yet.
        try keyStore.save(key: key, for: diaryId)

        TestURLProtocol.queue = [
            .init(status: 200, body: try requester.directoryJSON()),                        // targeted relay: lookup
            .init(status: 200, body: Data(#"{"challenge":"Q0hBTA=="}"#.utf8)),               // targeted relay: PoW
            .init(status: 201, body: Data(#"{"id":"01SENT0000000000000000000F"}"#.utf8)),    // targeted relay: send
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001","\#(requester.accountId.raw)"],"holderIndex":0,"seq":1,"state":"open","keyEpoch":1,"metaCipher":"\#(metaCipher)"}
            """#.utf8)),   // handlePush's own sync: GET meta
            .init(status: 200, body: Data(#"{"events":[]}"#.utf8)),   // handlePush's own sync: GET events, since=1
        ]
        await store.handlePush(kind: "diaryKeyRequest", diaryId: diaryId, accountId: requester.accountId.raw)

        XCTAssertEqual(TestURLProtocol.requests.count, 7)   // 2 (seed) + 5 (this push)
        let sendCount = TestURLProtocol.requests.filter { $0.url?.path == "/v3/notes/\(requester.accountId.raw)" }.count
        XCTAssertEqual(sendCount, 1)   // exactly one send for the requester across the whole call
    }

    // MARK: - syncList refreshes every known diary, not only new ones (review round 1, I5)

    func testSyncListRefreshesAnAlreadyKnownDiarysTurnState() async throws {
        let diaryId = try await createDiary()   // this device is the owner/holder at creation
        XCTAssertTrue(store.states[diaryId]?.isHolder ?? false)

        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"[{"diaryId":"\#(diaryId)","joinedAt":1700000000000}]"#.utf8)),   // client.list()
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001","OTHRMBR1"],"holderIndex":1,"seq":0,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
            """#.utf8)),   // sync's GET meta — someone ELSE now holds the turn
            .init(status: 200, body: Data(#"{"events":[]}"#.utf8)),
        ]
        await store.syncList()

        let summary = try XCTUnwrap(store.diaries.first { $0.diaryId == diaryId })
        XCTAssertFalse(summary.isMyTurn)
        XCTAssertEqual(summary.holderAccountId, "OTHRMBR1")
        XCTAssertFalse(store.states[diaryId]?.isHolder ?? true)
    }

    // MARK: - C2: performWrite landing ahead of the sync cursor doesn't skip the gap

    /// The event log's own `maxSeq` must never drive `since` — only a
    /// persisted, GET-driven-only cursor. Seed the cursor at 10 (a real
    /// paged sync), then have a write land at seq 16 (as if OTHER members
    /// pushed 11–15 in the meantime, unsynced) — the NEXT sync must still
    /// ask for `since=10`, not `since=16`, or 11–15 (and any `join` event
    /// among them) would be skipped forever.
    func testPerformWriteLandingAheadOfTheCursorDoesNotSkipTheGapOnTheNextSync() async throws {
        let diaryId = did("CRSRGAP1")
        let seedEvents = (1...10).map { seq in
            #"{"seq":\#(seq),"eventId":"E\#(seq)","type":"pass","authorAccountId":"0WNER001","createdAt":\#(1_700_000_000_000 + seq)}"#
        }.joined(separator: ",")
        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001"],"holderIndex":0,"seq":10,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
            """#.utf8)),
            .init(status: 200, body: Data(#"{"events":[\#(seedEvents)]}"#.utf8)),
        ]
        await store.sync(diaryId)
        XCTAssertEqual(store.states[diaryId]?.events.count, 10)

        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"seq":16,"holderIndex":0}"#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":16,"eventId":"E16","type":"pass","authorAccountId":"0WNER001","createdAt":1700000016000}]}
            """#.utf8)),
        ]
        try await store.pass(diaryId)

        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001"],"holderIndex":0,"seq":16,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
            """#.utf8)),
            .init(status: 200, body: Data(#"{"events":[]}"#.utf8)),
        ]
        await store.sync(diaryId)

        XCTAssertEqual(TestURLProtocol.requests.last?.url?.query, "since=10&limit=100")
    }

    // MARK: - I1: a stuck pending create is only resumable for the SAME name

    func testCreateWithADifferentNameAbandonsTheStuckPendingCreateAndItsKey() async throws {
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        do {
            _ = try await store.create(name: "A")
            XCTFail("expected .transient")
        } catch {
            XCTAssertEqual(error as? DiaryError, .transient("http_500"))
        }
        let diaryIdA = body(TestURLProtocol.requests.count - 1)["diaryId"] as! String
        XCTAssertNotNil(keyStore.key(for: diaryIdA))

        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"diaryId":"IGNORED00000000000000000Z","inviteCode":"CODEB001"}"#.utf8))]
        let diaryIdB = try await store.create(name: "B")

        XCTAssertNotEqual(diaryIdB, diaryIdA)
        XCTAssertNil(keyStore.key(for: diaryIdA))   // A's key removed — abandoned, not reused
        XCTAssertNotNil(keyStore.key(for: diaryIdB))
        let stateB = try XCTUnwrap(store.states[diaryIdB])
        XCTAssertEqual(stateB.meta.name, "B")
    }

    // MARK: - I2: DiaryStore.sync reentrancy guard

    func testConcurrentSyncForTheSameDiaryOnlyRunsOnce() async throws {
        let diaryId = did("SYNCRE1")
        // Only ONE set of stubs — if `sync` ran twice concurrently for the
        // same id, a second GET meta/events pair would either be missing
        // (hitting the default 500 stub) or consumed out of order; either
        // way the request count below would no longer be exactly 2.
        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001"],"holderIndex":0,"seq":0,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
            """#.utf8)),
            .init(status: 200, body: Data(#"{"events":[]}"#.utf8)),
        ]
        async let first: Void = store.sync(diaryId)
        async let second: Void = store.sync(diaryId)
        _ = await (first, second)

        XCTAssertEqual(TestURLProtocol.requests.count, 2)
    }

    // MARK: - Minors: load() rehydration after relaunch, pending.enc on disk before the POST

    func testLoadRehydratesFromIndexAfterARelaunch() async throws {
        let diaryId = try await createDiary(name: "Persisted Diary")

        // A brand-new `DiaryStore` over the SAME directory/keyStore —
        // simulates an app relaunch. `load()` runs automatically from the
        // real `init`.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TestURLProtocol.self]
        let account = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg), authProvider: { _ in }, tokenInvalidator: {})
        let manager = AccountManager(mock: Account(accountId: myAccountId, nickname: "owner", mailboxId: "mbx", createdAt: Date()))
        let relaunchedStore = DiaryStore(client: DiaryClient(account: account), notesClient: NotesClient(account: account), accountManager: manager,
                                         crypto: DiaryFakeCrypto(), keyStore: keyStore, directory: dir, encryptor: encryptor, directoryCache: DirectoryCache())

        let summary = try XCTUnwrap(relaunchedStore.diaries.first { $0.diaryId == diaryId })
        XCTAssertEqual(summary.name, "Persisted Diary")
        let state = try XCTUnwrap(relaunchedStore.states[diaryId])
        XCTAssertTrue(state.hasKey)
        XCTAssertTrue(state.isOwner)
    }

    func testPendingEventFileExistsOnDiskRegardlessOfThePostOutcome() async throws {
        let diaryId = try await createDiary()
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        do {
            try await store.pass(diaryId)
            XCTFail("expected .transient")
        } catch {
            XCTAssertEqual(error as? DiaryError, .transient("http_500"))
        }
        let pending = try XCTUnwrap(readPendingEventDirectly(diaryId))
        XCTAssertEqual(pending.type, .pass)
        XCTAssertNil(pending.payloadCipher)
    }

    // MARK: - flushPendingIfPossible via sync(_:) (review round 2, defect 1)

    func testSyncFlushesAPendingEventSuccessfullyAndClearsTheSlot() async throws {
        let diaryId = try await createDiary()
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        do {
            try await store.pass(diaryId)
            XCTFail("expected .transient")
        } catch {
            XCTAssertEqual(error as? DiaryError, .transient("http_500"))
        }
        XCTAssertNotNil(readPendingEventDirectly(diaryId))

        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"seq":1,"holderIndex":1}"#.utf8)),   // flush: resend POST
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":1,"eventId":"FLUSHED1","type":"pass","authorAccountId":"0WNER001","createdAt":1700000000000}]}
            """#.utf8)),   // flush: fetch the canonical event
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001"],"holderIndex":1,"seq":1,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
            """#.utf8)),   // sync's own GET meta
            .init(status: 200, body: Data(#"{"events":[]}"#.utf8)),   // sync's own events page (since=1, nothing new)
        ]
        await store.sync(diaryId)

        XCTAssertNil(readPendingEventDirectly(diaryId))
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.states[diaryId]?.events.map(\.eventId), ["FLUSHED1"])
    }

    func testSyncFlushKeepsThePendingSlotOnATransientFailureAndStillProceeds() async throws {
        let diaryId = try await createDiary()
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        do {
            try await store.pass(diaryId)
            XCTFail("expected .transient")
        } catch {
            XCTAssertEqual(error as? DiaryError, .transient("http_500"))
        }
        let stuck = try XCTUnwrap(readPendingEventDirectly(diaryId))

        TestURLProtocol.queue = [
            .init(status: 500, body: Data()),   // flush's own resend ALSO fails transiently
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001"],"holderIndex":0,"seq":0,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
            """#.utf8)),   // sync's own GET meta — proceeds regardless of the flush failure
            .init(status: 200, body: Data(#"{"events":[]}"#.utf8)),
        ]
        await store.sync(diaryId)

        // No error escalation beyond `lastError` — `sync` itself doesn't
        // throw/crash, and its own (unrelated) meta/events work still runs.
        XCTAssertEqual(store.lastError, String(describing: DiaryError.transient("http_500")))
        let stillPending = try XCTUnwrap(readPendingEventDirectly(diaryId))
        XCTAssertEqual(stillPending.eventId, stuck.eventId)
        XCTAssertNotNil(store.states[diaryId])
    }

    func testSyncFlushClearsThePendingSlotOnAHardFailureAndSetsLastError() async throws {
        let diaryId = try await createDiary()
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        do {
            try await store.pass(diaryId)
            XCTFail("expected .transient")
        } catch {
            XCTAssertEqual(error as? DiaryError, .transient("http_500"))
        }
        XCTAssertNotNil(readPendingEventDirectly(diaryId))

        TestURLProtocol.queue = [
            .init(status: 403, body: Data(#"{"error":"not_holder"}"#.utf8)),   // flush's own resend fails HARD
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001"],"holderIndex":0,"seq":0,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
            """#.utf8)),   // sync's own GET meta succeeds afterward
            .init(status: 200, body: Data(#"{"events":[]}"#.utf8)),
        ]
        await store.sync(diaryId)

        // A dead pending event (403 forever) must be cleared — not resent
        // and failed identically on every future sync — and `lastError`
        // reflects the hard failure even though sync's OWN work succeeded.
        XCTAssertNil(readPendingEventDirectly(diaryId))
        XCTAssertEqual(store.lastError, String(describing: DiaryError.notHolder))
    }

    // MARK: - Per-diary serial gate (review round 2, defect 2)

    /// `sync` and `writeEntry` for the SAME diary, started concurrently,
    /// must never interleave their `cursor.enc`/`pending.enc`/`meta.enc`
    /// read-modify-writes. `sync` is declared (and so started) first, and
    /// the gate makes its entire body run to completion before
    /// `writeEntry`'s starts — the stub queue below is ordered to match
    /// exactly that (sync's GET meta/events, THEN the write's POST/GET).
    func testConcurrentSyncAndWriteEntryForTheSameDiaryDoNotRaceCursorOrPending() async throws {
        let diaryId = did("GATE1")
        let seedEvents = (1...10).map { seq in
            #"{"seq":\#(seq),"eventId":"E\#(seq)","type":"pass","authorAccountId":"0WNER001","createdAt":\#(1_700_000_000_000 + seq)}"#
        }.joined(separator: ",")
        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001"],"holderIndex":0,"seq":10,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
            """#.utf8)),
            .init(status: 200, body: Data(#"{"events":[\#(seedEvents)]}"#.utf8)),
        ]
        await store.sync(diaryId)
        XCTAssertEqual(store.states[diaryId]?.events.count, 10)

        let key = SymmetricKey(size: .bits256)
        try keyStore.save(key: key, for: diaryId)

        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001"],"holderIndex":0,"seq":15,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
            """#.utf8)),   // sync: GET meta
            .init(status: 200, body: Data(#"""
            {"events":[
              {"seq":11,"eventId":"E11","type":"pass","authorAccountId":"0WNER001","createdAt":1700000011000},
              {"seq":12,"eventId":"E12","type":"pass","authorAccountId":"0WNER001","createdAt":1700000012000},
              {"seq":13,"eventId":"E13","type":"pass","authorAccountId":"0WNER001","createdAt":1700000013000},
              {"seq":14,"eventId":"E14","type":"pass","authorAccountId":"0WNER001","createdAt":1700000014000},
              {"seq":15,"eventId":"E15","type":"pass","authorAccountId":"0WNER001","createdAt":1700000015000}
            ]}
            """#.utf8)),   // sync: GET events since=10 → 11..15
            .init(status: 201, body: Data(#"{"seq":16,"holderIndex":0}"#.utf8)),   // write: POST
            .init(status: 200, body: Data(#"""
            {"events":[{"seq":16,"eventId":"E16","type":"entry","authorAccountId":"0WNER001","payloadCipher":"cGF5","createdAt":1700000016000}]}
            """#.utf8)),   // write: GET event
        ]

        // `async let` declaration order is NOT a reliable signal for which
        // task actually reaches `withDiaryLock`'s (synchronous) gate
        // registration first — empirically flaky when this test runs
        // alongside a full suite (other queued MainActor work can let the
        // second-declared task run first). A short real sleep after
        // starting `sync` gives it an overwhelming margin to register
        // itself in the gate before `writeEntry` starts, while the two
        // still genuinely run concurrently afterward (both in flight, real
        // `Task`s, real `await`s) — the stub queue is ordered to match
        // this now-deterministic "sync's gated body completes fully
        // first" outcome.
        let syncTask = Task { await store.sync(diaryId) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let writeTask = Task<DiaryError?, Never> {
            do {
                try await store.writeEntry(diaryId, text: "concurrent write")
                return nil
            } catch {
                return error as? DiaryError
            }
        }
        let writeError = await writeTask.value
        _ = await syncTask.value

        XCTAssertNil(writeError)
        XCTAssertNil(readPendingEventDirectly(diaryId))   // exactly one clean round trip — never stuck
        XCTAssertEqual(store.states[diaryId]?.events.count, 16)

        let cursorURL = dir.appendingPathComponent(diaryId, isDirectory: true).appendingPathComponent("cursor.enc")
        let cursorData = try XCTUnwrap(try? encryptor.readAndDecrypt(from: cursorURL))
        struct DirectCursorFile: Codable { let syncedThrough: Int }
        let cursor = try JSONDecoder().decode(DirectCursorFile.self, from: cursorData)
        XCTAssertGreaterThanOrEqual(cursor.syncedThrough, 15)
    }

    /// Review round 3: `acceptRelayedKey` is now gated by `withDiaryLock`
    /// the same as `sync` — racing them for the SAME diary must not
    /// interleave their `meta.enc`/`key.enc`/`cursor.enc` read-modify-writes.
    /// Uses the same `Task` + priming-sleep determinism as the
    /// `sync`/`writeEntry` gate test above (see its doc comment) rather
    /// than relying on `async let` declaration order.
    func testAcceptRelayedKeyRacingSyncForTheSameDiaryCompletesWithoutInterleaving() async throws {
        let diaryId = did("GATEKEY1")
        let key = SymmetricKey(size: .bits256)
        let metaCipher = try DiaryCrypto.sealMeta(name: "Diary", key: key, diaryId: diaryId, keyEpoch: 1).base64EncodedString()

        // Seed: this device knows the diary (meta persisted, synced
        // through seq 2) but doesn't hold the key yet.
        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001"],"holderIndex":0,"seq":2,"state":"open","keyEpoch":1,"metaCipher":"\#(metaCipher)"}
            """#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[
              {"seq":1,"eventId":"E1","type":"pass","authorAccountId":"0WNER001","createdAt":1700000001000},
              {"seq":2,"eventId":"E2","type":"pass","authorAccountId":"0WNER001","createdAt":1700000002000}
            ]}
            """#.utf8)),
        ]
        await store.sync(diaryId)
        XCTAssertFalse(store.states[diaryId]?.hasKey ?? true)

        let plaintext = try relayPlaintext(diaryId: diaryId, key: key, senderAccountId: "0WNER001")

        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"""
            {"diaryId":"\#(diaryId)","ownerAccountId":"0WNER001","members":["0WNER001"],"holderIndex":0,"seq":5,"state":"open","keyEpoch":1,"metaCipher":"\#(metaCipher)"}
            """#.utf8)),
            .init(status: 200, body: Data(#"""
            {"events":[
              {"seq":3,"eventId":"E3","type":"pass","authorAccountId":"0WNER001","createdAt":1700000003000},
              {"seq":4,"eventId":"E4","type":"pass","authorAccountId":"0WNER001","createdAt":1700000004000},
              {"seq":5,"eventId":"E5","type":"pass","authorAccountId":"0WNER001","createdAt":1700000005000}
            ]}
            """#.utf8)),
        ]

        let syncTask = Task { await store.sync(diaryId) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let keyTask = Task {
            await store.acceptRelayedKey(plaintext, sender: .verified(accountId: "0WNER001", nickname: nil))
        }
        let disposition = await keyTask.value
        _ = await syncTask.value

        assertDisposition(disposition, .installed)
        XCTAssertNotNil(keyStore.key(for: diaryId))
        XCTAssertTrue(store.states[diaryId]?.hasKey ?? false)

        let cursorURL = dir.appendingPathComponent(diaryId, isDirectory: true).appendingPathComponent("cursor.enc")
        let cursorData = try XCTUnwrap(try? encryptor.readAndDecrypt(from: cursorURL))
        struct DirectCursorFile: Codable { let syncedThrough: Int }
        let cursor = try JSONDecoder().decode(DirectCursorFile.self, from: cursorData)
        XCTAssertGreaterThanOrEqual(cursor.syncedThrough, 5)
    }

    // MARK: - inviteLink(for:) / resetInvite (Task 6 fix round 1: F4)

    /// `inviteLink(for:)` builds a `peerdrop://diary/<id>?code=...#k=...`
    /// link out of purely local state (owner-only `inviteCode` + this
    /// device's content key, both already present right after `create`) —
    /// `DiaryInviteLink.parse` must recover exactly the same diaryId,
    /// invite code, and raw key bytes from that link.
    func testInviteLinkRoundTripsThroughDiaryInviteLinkParse() async throws {
        let diaryId = try await createDiary(name: "Link Diary")

        let link = try XCTUnwrap(store.inviteLink(for: diaryId))
        let parsed = try XCTUnwrap(DiaryInviteLink.parse(link))

        XCTAssertEqual(parsed.diaryId, diaryId)
        XCTAssertEqual(parsed.code, "CODE0001")   // stubbed by createDiary()'s create response
        let localKey = try XCTUnwrap(keyStore.key(for: diaryId))
        XCTAssertEqual(parsed.key, localKey.withUnsafeBytes { Data($0) })
    }

    /// `resetInvite` (spec §6: "重設邀請碼只讓舊碼失效，金鑰不變") must persist
    /// the new code locally, not just relay the client's success back to
    /// the caller — `inviteLink(for:)` (and the raw `meta.inviteCode`)
    /// have to reflect it afterwards. Mocks the client response the same
    /// way `DiaryClientTests.testResetInviteReturnsNewCode` does.
    func testResetInviteUpdatesTheStoredInviteCode() async throws {
        let diaryId = try await createDiary(name: "Reset Diary")
        XCTAssertEqual(store.states[diaryId]?.meta.inviteCode, "CODE0001")
        let keyBeforeReset = try XCTUnwrap(keyStore.key(for: diaryId)).withUnsafeBytes { Data($0) }

        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"inviteCode":"NEWCODE1"}"#.utf8))]
        let newCode = try await store.resetInvite(diaryId)

        XCTAssertEqual(newCode, "NEWCODE1")
        XCTAssertEqual(store.states[diaryId]?.meta.inviteCode, "NEWCODE1")
        // The key is unaffected by a code reset.
        XCTAssertEqual(try XCTUnwrap(keyStore.key(for: diaryId)).withUnsafeBytes { Data($0) }, keyBeforeReset)

        let link = try XCTUnwrap(store.inviteLink(for: diaryId))
        let parsed = try XCTUnwrap(DiaryInviteLink.parse(link))
        XCTAssertEqual(parsed.code, "NEWCODE1")
    }
}
