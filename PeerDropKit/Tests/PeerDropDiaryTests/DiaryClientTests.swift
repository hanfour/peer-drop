import XCTest
import PeerDropAccount
import PeerDropNotes
@testable import PeerDropDiary

final class DiaryClientTests: XCTestCase {
    private var client: DiaryClient!

    override func setUp() {
        TestURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TestURLProtocol.self]
        let account = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg),
                                    authProvider: { $0.setValue("Bearer t", forHTTPHeaderField: "Authorization") }, tokenInvalidator: {})
        client = DiaryClient(account: account)
    }

    private func body(_ i: Int) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: TestURLProtocol.requests[i].httpBody ?? Data()) as! [String: Any]
    }

    /// A syntactically-valid diary id (`^[0-9A-HJKMNP-TV-Z]{26}$`) built
    /// from a short valid-alphabet label padded to 26 chars with `0` — every
    /// `DiaryClient` call that embeds an id in a URL path now validates it,
    /// so tests can no longer use an arbitrary short placeholder like "D1".
    private func did(_ label: String) -> String {
        precondition(label.count <= 26)
        return label + String(repeating: "0", count: 26 - label.count)
    }

    // MARK: - create

    func testCreatePostsDiaryIdAndMetaCipherAndDecodesInviteCode() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"diaryId":"01DIARY0000000000000000000","inviteCode":"ABCD1234"}"#.utf8))]
        let r = try await client.create(diaryId: "01DIARY0000000000000000000", metaCipher: "bWV0YQ==")
        XCTAssertEqual(r.diaryId, "01DIARY0000000000000000000")
        XCTAssertEqual(r.inviteCode, "ABCD1234")
        XCTAssertEqual(TestURLProtocol.requests.count, 1)
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries")
        XCTAssertEqual(TestURLProtocol.requests[0].httpMethod, "POST")
        XCTAssertEqual(body(0)["diaryId"] as? String, "01DIARY0000000000000000000")
        XCTAssertEqual(body(0)["metaCipher"] as? String, "bWV0YQ==")
        XCTAssertEqual(TestURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testCreateIdempotentReCreateReturns200() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"diaryId":"D1","inviteCode":"SAME0000"}"#.utf8))]
        let r = try await client.create(diaryId: "D1", metaCipher: "x")
        XCTAssertEqual(r.inviteCode, "SAME0000")
    }

    // MARK: - list

    func testListDecodesJoinedAtAsDate() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"[{"diaryId":"D1","joinedAt":1700000000000},{"diaryId":"D2","joinedAt":1700000005000}]"#.utf8))]
        let rows = try await client.list()
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries")
        XCTAssertEqual(TestURLProtocol.requests[0].httpMethod, "GET")
        XCTAssertEqual(rows.map(\.diaryId), ["D1", "D2"])
        XCTAssertEqual(rows[0].joinedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        XCTAssertEqual(rows[1].joinedAt.timeIntervalSince1970, 1_700_000_005, accuracy: 0.001)
    }

    // MARK: - get

    func testGetDecodesFullMetaIncludingOwnerOnlyInviteCode() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"""
        {"diaryId":"D1","ownerAccountId":"OWNER1","members":["OWNER1","M2"],"holderIndex":1,"seq":5,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ==","inviteCode":"CODE1234"}
        """#.utf8))]
        let meta = try await client.get(did("D1"))
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries/\(did("D1"))")
        XCTAssertEqual(TestURLProtocol.requests[0].httpMethod, "GET")
        XCTAssertEqual(meta.diaryId, "D1")
        XCTAssertEqual(meta.ownerAccountId, "OWNER1")
        XCTAssertEqual(meta.members, ["OWNER1", "M2"])
        XCTAssertEqual(meta.holderIndex, 1)
        XCTAssertEqual(meta.seq, 5)
        XCTAssertEqual(meta.state, "open")
        XCTAssertEqual(meta.keyEpoch, UInt32(1))
        XCTAssertEqual(meta.metaCipher, "bWV0YQ==")
        XCTAssertEqual(meta.inviteCode, "CODE1234")
        XCTAssertNil(meta.name)   // never on the wire — decrypted locally by a later layer
    }

    func testGetForNonOwnerHasNoInviteCode() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"""
        {"diaryId":"D1","ownerAccountId":"OWNER1","members":["OWNER1","M2"],"holderIndex":0,"seq":0,"state":"open","keyEpoch":1,"metaCipher":"bWV0YQ=="}
        """#.utf8))]
        let meta = try await client.get(did("D1"))
        XCTAssertNil(meta.inviteCode)
    }

    /// A caller-supplied `id` that could never be a real diaryId (here, a
    /// path-traversal attempt) must be rejected BEFORE any `URLRequest` is
    /// built — never interpolated into a URL path.
    func testGetWithInvalidIdThrowsBadIdAndIssuesNoRequest() async {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"diaryId":"x"}"#.utf8))]  // must never be consumed
        do {
            _ = try await client.get("../../v3/account")
            XCTFail("expected .badId")
        } catch {
            XCTAssertEqual(error as? DiaryError, .badId)
        }
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    func testGetWithWrongLengthIdThrowsBadId() async {
        do {
            _ = try await client.get("TOOSHORT")
            XCTFail("expected .badId")
        } catch {
            XCTAssertEqual(error as? DiaryError, .badId)
        }
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    func testGetWithLowercaseIdThrowsBadId() async {
        do {
            _ = try await client.get(did("D1").lowercased())
            XCTFail("expected .badId")
        } catch {
            XCTAssertEqual(error as? DiaryError, .badId)
        }
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    // MARK: - join

    func testJoinByLinkPostsInviteCodeAndDefaultsKeyEpochToOne() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"""
        {"diaryId":"D1","members":["OWNER1","M2"],"holderIndex":0,"ownerAccountId":"OWNER1","state":"open","seq":1,"metaCipher":"bWV0YQ=="}
        """#.utf8))]
        let meta = try await client.join(id: did("D1"), code: "CODE1234")
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries/\(did("D1"))/join")
        XCTAssertEqual(TestURLProtocol.requests[0].httpMethod, "POST")
        XCTAssertEqual(body(0)["inviteCode"] as? String, "CODE1234")
        XCTAssertEqual(meta.members, ["OWNER1", "M2"])
        XCTAssertEqual(meta.keyEpoch, UInt32(1))     // never on the wire for join — MVP-fixed
        XCTAssertNil(meta.inviteCode)        // never on the wire for join either
    }

    func testJoinByLinkIdempotentReJoinReturns200() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"""
        {"diaryId":"D1","members":["OWNER1","M2"],"holderIndex":0,"ownerAccountId":"OWNER1","state":"open","seq":1,"metaCipher":"bWV0YQ=="}
        """#.utf8))]
        let meta = try await client.join(id: did("D1"), code: "CODE1234")
        XCTAssertEqual(meta.diaryId, "D1")
    }

    func testJoinWithInvalidIdThrowsBadIdAndIssuesNoRequest() async {
        do {
            _ = try await client.join(id: "not-a-ulid", code: "CODE1234")
            XCTFail("expected .badId")
        } catch {
            XCTAssertEqual(error as? DiaryError, .badId)
        }
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    func testJoinByCodeOnlyPostsToTheCodeOnlyRoute() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"""
        {"diaryId":"D9","members":["OWNER1","M2"],"holderIndex":0,"ownerAccountId":"OWNER1","state":"open","seq":1,"metaCipher":"bQ=="}
        """#.utf8))]
        let meta = try await client.joinByCode("CODE1234")
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries/join")
        XCTAssertEqual(TestURLProtocol.requests[0].httpMethod, "POST")
        XCTAssertEqual(body(0)["inviteCode"] as? String, "CODE1234")
        XCTAssertEqual(meta.diaryId, "D9")
    }

    // MARK: - leave / close / invite reset

    func testLeavePostsToLeaveRouteAndSucceedsOn204() async throws {
        TestURLProtocol.queue = [.init(status: 204, body: Data())]
        try await client.leave(did("D1"))
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries/\(did("D1"))/leave")
        XCTAssertEqual(TestURLProtocol.requests[0].httpMethod, "POST")
    }

    func testClosePostsToCloseRouteAndSucceedsOn204() async throws {
        TestURLProtocol.queue = [.init(status: 204, body: Data())]
        try await client.close(did("D1"))
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries/\(did("D1"))/close")
        XCTAssertEqual(TestURLProtocol.requests[0].httpMethod, "POST")
    }

    func testResetInviteReturnsNewCode() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"inviteCode":"NEWCODE1"}"#.utf8))]
        let code = try await client.resetInvite(did("D1"))
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries/\(did("D1"))/invite/reset")
        XCTAssertEqual(TestURLProtocol.requests[0].httpMethod, "POST")
        XCTAssertEqual(code, "NEWCODE1")
    }

    // MARK: - events list

    func testEventsListSendsSinceAndLimitAndDecodesFields() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"""
        {"events":[
          {"seq":1,"eventId":"E1","type":"entry","authorAccountId":"A1","payloadCipher":"cGF5","createdAt":1700000000000},
          {"seq":2,"eventId":"E2","type":"skip","authorAccountId":"OWNER1","createdAt":1700000001000,"skipped":"A1"}
        ],"nextSince":2}
        """#.utf8))]
        let (events, nextSince) = try await client.events(id: did("D1"), since: 0, limit: 50)
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries/\(did("D1"))/events")
        XCTAssertEqual(TestURLProtocol.requests[0].url?.query, "since=0&limit=50")
        XCTAssertEqual(nextSince, 2)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].seq, 1)
        XCTAssertEqual(events[0].type, .entry)
        XCTAssertEqual(events[0].payloadCipher, "cGF5")
        XCTAssertNil(events[0].payload)   // not decrypted by the client
        XCTAssertEqual(events[0].createdAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        XCTAssertEqual(events[1].type, .skip)
        XCTAssertEqual(events[1].skipped, "A1")
        XCTAssertNil(events[1].refSeq)
        XCTAssertNil(events[1].payloadCipher)
    }

    func testEventsListOmitsNextSinceWhenThereIsNoMorePage() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"events":[]}"#.utf8))]
        let (events, nextSince) = try await client.events(id: did("D1"), since: 10, limit: 10)
        XCTAssertEqual(events, [])
        XCTAssertNil(nextSince)
    }

    func testEventsWithInvalidIdThrowsBadIdAndIssuesNoRequest() async {
        do {
            _ = try await client.events(id: "bad id", since: 0, limit: 10)
            XCTFail("expected .badId")
        } catch {
            XCTAssertEqual(error as? DiaryError, .badId)
        }
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    // MARK: - postEvent — 200 and 201 both decode holderIndex

    func testPostEventNewEventReturns201WithSeqAndHolderIndex() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"seq":7,"holderIndex":2}"#.utf8))]
        let r = try await client.postEvent(id: did("D1"), eventId: "E7", type: .entry, payloadCipher: "cGF5")
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries/\(did("D1"))/events")
        XCTAssertEqual(TestURLProtocol.requests[0].httpMethod, "POST")
        XCTAssertEqual(body(0)["eventId"] as? String, "E7")
        XCTAssertEqual(body(0)["type"] as? String, "entry")
        XCTAssertEqual(body(0)["payloadCipher"] as? String, "cGF5")
        XCTAssertNil(body(0)["refSeq"])
        XCTAssertEqual(r.seq, 7)
        XCTAssertEqual(r.holderIndex, 2)
    }

    func testPostEventIdempotentResendReturns200WithSameShape() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"seq":7,"holderIndex":2}"#.utf8))]
        let r = try await client.postEvent(id: did("D1"), eventId: "E7", type: .entry, payloadCipher: "cGF5")
        XCTAssertEqual(r.seq, 7)
        XCTAssertEqual(r.holderIndex, 2)
    }

    func testPostEventCommentIncludesRefSeqAndOmitsPayloadWhenNil() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"seq":8,"holderIndex":2}"#.utf8))]
        _ = try await client.postEvent(id: did("D1"), eventId: "E8", type: .like, refSeq: 7, payloadCipher: nil)
        XCTAssertEqual(body(0)["refSeq"] as? Int, 7)
        XCTAssertEqual(body(0)["type"] as? String, "like")
        XCTAssertNil(body(0)["payloadCipher"])
    }

    // MARK: - event(id:seq:) — no dedicated HTTP route, falls back to events(since:limit:)

    func testEventBySeqFetchesViaSinceMinusOneLimitOne() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"""
        {"events":[{"seq":5,"eventId":"E5","type":"entry","authorAccountId":"A1","payloadCipher":"cGF5","createdAt":1700000000000}]}
        """#.utf8))]
        let event = try await client.event(id: did("D1"), seq: 5)
        XCTAssertEqual(TestURLProtocol.requests[0].url?.query, "since=4&limit=1")
        XCTAssertEqual(event.seq, 5)
        XCTAssertEqual(event.eventId, "E5")
    }

    func testEventBySeqOneUsesSinceZero() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"""
        {"events":[{"seq":1,"eventId":"E1","type":"entry","authorAccountId":"A1","payloadCipher":"cGF5","createdAt":1700000000000}]}
        """#.utf8))]
        _ = try await client.event(id: did("D1"), seq: 1)
        XCTAssertEqual(TestURLProtocol.requests[0].url?.query, "since=0&limit=1")
    }

    func testEventBySeqThrowsNotFoundWhenMissingFromThePage() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"events":[]}"#.utf8))]
        do {
            _ = try await client.event(id: did("D1"), seq: 5)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DiaryError, .notFound)
        }
    }

    /// A genuine 404 from the worker (e.g. a diaryId that resolves to
    /// nothing in D1) unifies to the SAME `.notFound` case as the synthetic
    /// "not present in this page" condition above.
    func testEventBySeqThrowsNotFoundOnAGenuine404() async {
        TestURLProtocol.queue = [.init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))]
        do {
            _ = try await client.event(id: did("D1"), seq: 5)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DiaryError, .notFound)
        }
    }

    // MARK: - request-key / report

    func testRequestKeyPostsAndSucceedsOn204() async throws {
        TestURLProtocol.queue = [.init(status: 204, body: Data())]
        try await client.requestKey(did("D1"))
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries/\(did("D1"))/request-key")
        XCTAssertEqual(TestURLProtocol.requests[0].httpMethod, "POST")
    }

    func testReportPostsReasonAndExcerptAndReturnsId() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"id":"R1"}"#.utf8))]
        let id = try await client.report(id: did("D1"), seq: 3, reason: .harassment, excerpt: "excerpt text")
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/diaries/\(did("D1"))/events/3/report")
        XCTAssertEqual(TestURLProtocol.requests[0].httpMethod, "POST")
        XCTAssertEqual(body(0)["reason"] as? String, "harassment")
        XCTAssertEqual(body(0)["excerpt"] as? String, "excerpt text")
        XCTAssertEqual(id, "R1")
    }

    func testReportWithoutExcerptOmitsTheKey() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"id":"R2"}"#.utf8))]
        _ = try await client.report(id: did("D1"), seq: 3, reason: .spam, excerpt: nil)
        XCTAssertNil(body(0)["excerpt"])
    }

    func testReportWithInvalidIdThrowsBadIdAndIssuesNoRequest() async {
        do {
            _ = try await client.report(id: "..", seq: 3, reason: .spam, excerpt: nil)
            XCTFail("expected .badId")
        } catch {
            XCTAssertEqual(error as? DiaryError, .badId)
        }
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    // MARK: - error mapping (AccountClientError → DiaryError by body code)

    func testForbiddenCodesMapToTheirNamedDiaryErrors() async {
        let cases: [(String, DiaryError)] = [
            ("not_member", .notMember), ("not_holder", .notHolder), ("not_owner", .notOwner),
            ("skip_self", .skipSelf), ("diary_closed", .closed), ("bad_code", .badCode),
        ]
        for (code, expected) in cases {
            TestURLProtocol.queue = [.init(status: 403, body: Data(#"{"error":"\#(code)"}"#.utf8))]
            do { try await client.requestKey(did("D1")); XCTFail("expected \(expected) for \(code)") }
            catch { XCTAssertEqual(error as? DiaryError, expected, "code \(code)") }
        }
    }

    func testConflictCodesMapToTheirNamedDiaryErrors() async {
        let cases: [(String, DiaryError)] = [
            ("diary_limit", .limit), ("diary_full_members", .membersFull), ("diary_exists", .exists),
        ]
        for (code, expected) in cases {
            TestURLProtocol.queue = [.init(status: 409, body: Data(#"{"error":"\#(code)"}"#.utf8))]
            do { _ = try await client.create(diaryId: "D1", metaCipher: "x"); XCTFail("expected \(expected) for \(code)") }
            catch { XCTAssertEqual(error as? DiaryError, expected, "code \(code)") }
        }
    }

    func testTooLargeMapsFromA413() async {
        TestURLProtocol.queue = [.init(status: 413, body: Data(#"{"error":"too_large"}"#.utf8))]
        do { _ = try await client.postEvent(id: did("D1"), eventId: "E1", type: .entry, payloadCipher: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? DiaryError, .tooLarge) }
    }

    func testBadRefMapsFromA400() async {
        TestURLProtocol.queue = [.init(status: 400, body: Data(#"{"error":"bad_ref"}"#.utf8))]
        do { _ = try await client.postEvent(id: did("D1"), eventId: "E1", type: .comment, refSeq: 999, payloadCipher: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? DiaryError, .badRef) }
    }

    func testInsufficientStorageDiaryFullMapsTo507() async {
        TestURLProtocol.queue = [.init(status: 507, body: Data(#"{"error":"diary_full"}"#.utf8))]
        do { _ = try await client.postEvent(id: did("D1"), eventId: "E1", type: .entry, payloadCipher: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? DiaryError, .full) }
    }

    func testUnrecognizedBodyCodeFallsBackToNetworkWithTheCode() async {
        TestURLProtocol.queue = [.init(status: 400, body: Data(#"{"error":"bad_type"}"#.utf8))]
        do { _ = try await client.postEvent(id: did("D1"), eventId: "E1", type: .entry, payloadCipher: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? DiaryError, .network("bad_type")) }
    }

    func testRateLimitedMapsToTransient() async {
        TestURLProtocol.queue = [.init(status: 429, body: Data(#"{"error":"rate_limited"}"#.utf8))]
        do { try await client.requestKey(did("D1")); XCTFail() }
        catch { XCTAssertEqual(error as? DiaryError, .transient("rate_limited")) }
    }

    func testServerErrorMapsToTransientWithTheStatusCode() async {
        TestURLProtocol.queue = [.init(status: 500, body: Data(#"{"error":"d1_error"}"#.utf8))]
        do { try await client.requestKey(did("D1")); XCTFail() }
        catch { XCTAssertEqual(error as? DiaryError, .transient("http_500")) }
    }

    func testAnother5xxAlsoMapsToTransient() async {
        TestURLProtocol.queue = [.init(status: 503, body: Data())]
        do { try await client.requestKey(did("D1")); XCTFail() }
        catch { XCTAssertEqual(error as? DiaryError, .transient("http_503")) }
    }

    func testAGenuine404OnAnOrdinaryRouteMapsToNotFound() async {
        TestURLProtocol.queue = [.init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))]
        do { _ = try await client.get(did("D1")); XCTFail() }
        catch { XCTAssertEqual(error as? DiaryError, .notFound) }
    }

    /// A raw transport failure (no HTTP response at all) also maps to
    /// `.transient` — tested directly against `DiaryError.from`, since
    /// `TestURLProtocol` always completes with a status and can't simulate
    /// `URLSession` failing before a response exists.
    func testURLErrorMapsToTransient() {
        let error = DiaryError.from(URLError(.notConnectedToInternet))
        XCTAssertEqual(error, .transient("transport_\(URLError.notConnectedToInternet.rawValue)"))
    }
}
