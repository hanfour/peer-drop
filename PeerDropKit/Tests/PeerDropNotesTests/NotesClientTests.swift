import XCTest
import PeerDropAccount
@testable import PeerDropNotes

final class NotesClientTests: XCTestCase {
    private var client: NotesClient!

    override func setUp() {
        TestURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TestURLProtocol.self]
        let account = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg),
                                    authProvider: { $0.setValue("Bearer t", forHTTPHeaderField: "Authorization") }, tokenInvalidator: {})
        client = NotesClient(account: account)
    }
    private func body(_ i: Int) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: TestURLProtocol.requests[i].httpBody ?? Data()) as! [String: Any]
    }

    func testChallengeAndSend() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"challenge":"QUJD"}"#.utf8)), .init(status: 201, body: Data(#"{"id":"01ITEM0000000000000000000A"}"#.utf8))]
        let challenge = try await client.powChallenge()
        XCTAssertEqual(challenge, "QUJD")
        let id = try await client.send(to: "TESTRCPT", envelopeBase64: "ZW52", challenge: "QUJD", nonce: 4242)
        XCTAssertEqual(id, "01ITEM0000000000000000000A")
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/pow/challenge")
        XCTAssertEqual(TestURLProtocol.requests[1].url?.path, "/v3/notes/TESTRCPT")
        XCTAssertEqual(TestURLProtocol.requests[1].httpMethod, "POST")
        XCTAssertEqual(body(1)["envelope"] as? String, "ZW52")
        XCTAssertEqual((body(1)["pow"] as? [String: Any])?["nonce"] as? Int, 4242)
        XCTAssertEqual(TestURLProtocol.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }
    func testSendDefaultBodyOmitsKindAndDiaryId() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"id":"01ITEM0000000000000000000B"}"#.utf8))]
        _ = try await client.send(to: "TESTRCPT", envelopeBase64: "ZW52", challenge: "QUJD", nonce: 1)
        XCTAssertNil(body(0)["kind"])
        XCTAssertNil(body(0)["diaryId"])
    }
    func testSendDiaryKeyBodyIncludesKindAndDiaryId() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"id":"01ITEM0000000000000000000C"}"#.utf8))]
        _ = try await client.send(to: "TESTRCPT", envelopeBase64: "ZW52", challenge: "QUJD", nonce: 1, kind: "diaryKey", diaryId: "DIARY001")
        XCTAssertEqual(body(0)["kind"] as? String, "diaryKey")
        XCTAssertEqual(body(0)["diaryId"] as? String, "DIARY001")
    }
    func testInboxReadDeleteBlockReport() async throws {
        TestURLProtocol.queue = [
            .init(status: 200, body: Data(#"{"items":[{"id":"01A","kind":"note","envelope":"ZW52","createdAt":1700000000000,"readAt":null}],"nextAfter":"01A"}"#.utf8)),
            .init(status: 204, body: Data()), .init(status: 204, body: Data()),
            .init(status: 200, body: Data(#"{"blocked":"abc"}"#.utf8)),
            .init(status: 201, body: Data(#"{"id":"01R"}"#.utf8)),
            .init(status: 200, body: Data(#"[{"senderHash":"abc","createdAt":1}]"#.utf8)),
            .init(status: 204, body: Data()),
        ]
        let page = try await client.inbox(after: "00Z", limit: 25)
        XCTAssertEqual(page.items, [InboxItemDTO(id: "01A", kind: "note", envelope: "ZW52", createdAt: 1_700_000_000_000, readAt: nil)])
        XCTAssertEqual(page.nextAfter, "01A")
        XCTAssertEqual(TestURLProtocol.requests[0].url?.query, "after=00Z&limit=25")
        try await client.markRead(id: "01A"); try await client.delete(id: "01A")
        XCTAssertEqual(TestURLProtocol.requests[1].url?.path, "/v3/inbox/01A/read"); XCTAssertEqual(TestURLProtocol.requests[1].httpMethod, "POST")
        XCTAssertEqual(TestURLProtocol.requests[2].httpMethod, "DELETE"); XCTAssertEqual(TestURLProtocol.requests[2].url?.path, "/v3/inbox/01A")
        let blocked = try await client.block(itemId: "01A")
        XCTAssertEqual(blocked, "abc")
        let reportId = try await client.report(itemId: "01A", reason: .harassment, excerpt: "txt")
        XCTAssertEqual(reportId, "01R")
        XCTAssertEqual(body(4)["reason"] as? String, "harassment"); XCTAssertEqual(body(4)["excerpt"] as? String, "txt")
        let blockList = try await client.blocks()
        XCTAssertEqual(blockList, [BlockDTO(senderHash: "abc", createdAt: 1)])
        try await client.unblock(senderHash: "abc")
        XCTAssertEqual(TestURLProtocol.requests[6].url?.path, "/v3/blocks/abc"); XCTAssertEqual(TestURLProtocol.requests[6].httpMethod, "DELETE")
    }
    func testReportWithoutExcerptOmitsTheKey() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"id":"01R"}"#.utf8))]
        _ = try await client.report(itemId: "01A", reason: .spam, excerpt: nil)
        XCTAssertNil(body(0)["excerpt"])
    }
    func testErrorMapping() async {
        TestURLProtocol.queue = [.init(status: 507, body: Data(#"{"error":"inbox_full"}"#.utf8)), .init(status: 404, body: Data(#"{"error":"recipient_not_found"}"#.utf8)), .init(status: 400, body: Data(#"{"error":"bad_pow"}"#.utf8))]
        do { _ = try await client.send(to: "X", envelopeBase64: "e", challenge: "c", nonce: 1); XCTFail() } catch { XCTAssertEqual(error as? AccountClientError, .insufficientStorage("inbox_full")) }
        do { _ = try await client.send(to: "X", envelopeBase64: "e", challenge: "c", nonce: 1); XCTFail() } catch { XCTAssertEqual(error as? AccountClientError, .http(404)) }
        do { _ = try await client.send(to: "X", envelopeBase64: "e", challenge: "c", nonce: 1); XCTFail() } catch { XCTAssertEqual(error as? AccountClientError, .invalid("bad_pow")) }
    }
}
