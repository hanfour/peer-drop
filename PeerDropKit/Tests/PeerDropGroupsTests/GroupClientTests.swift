import Foundation
import XCTest
import PeerDropAccount
import PeerDropNotes
@testable import PeerDropGroups

final class GroupClientTests: XCTestCase {
    private var client: GroupClient!

    private let groupId = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private let memberId = "01ARZ3NDEKTSV4RRFFQ69G5FAW"

    override func setUp() {
        TestURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let account = AccountClient(
            baseURL: URL(string: "https://worker.test")!,
            session: URLSession(configuration: configuration),
            authProvider: { $0.setValue("Bearer t", forHTTPHeaderField: "Authorization") },
            tokenInvalidator: {}
        )
        client = GroupClient(account: account)
    }

    private func body(_ index: Int) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: TestURLProtocol.requests[index].httpBody ?? Data()) as! [String: Any]
    }

    func testEndpointsUseWorkerPathsBodiesAndMemberHeaders() async throws {
        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"groupId":"01ARZ3NDEKTSV4RRFFQ69G5FAV","inviteCode":"JOIN1234"}"#.utf8)),
            .init(status: 200, body: Data(#"[{"groupId":"01ARZ3NDEKTSV4RRFFQ69G5FAV","joinedAt":1700000000000}]"#.utf8)),
            .init(status: 200, body: Data(#"{"groupId":"01ARZ3NDEKTSV4RRFFQ69G5FAV","ownerMemberId":"01ARZ3NDEKTSV4RRFFQ69G5FAW","members":[{"memberId":"01ARZ3NDEKTSV4RRFFQ69G5FAW","kind":"account","accountId":"ACCOUNT1","joinedAt":1700000000000,"pubKey":"cHVi","pubKeySig":"c2ln","hasKey":true}],"joinPolicy":"accountOnly","state":"open","epoch":1,"seq":0,"firstSeq":1,"metaVersion":1,"rotationDue":false,"inviteCode":"JOIN1234"}"#.utf8)),
            .init(status: 201, body: Data(#"{"groupId":"01ARZ3NDEKTSV4RRFFQ69G5FAV","memberId":"01ARZ3NDEKTSV4RRFFQ69G5FAW","epoch":1,"state":"open","ownerMemberId":"01ARZ3NDEKTSV4RRFFQ69G5FAW"}"#.utf8)),
            .init(status: 201, body: Data(#"{"groupId":"01ARZ3NDEKTSV4RRFFQ69G5FAV","memberId":"01ARZ3NDEKTSV4RRFFQ69G5FAW","epoch":1,"state":"open","ownerMemberId":"01ARZ3NDEKTSV4RRFFQ69G5FAW"}"#.utf8)),
            .init(status: 204, body: Data()),
            .init(status: 204, body: Data()),
            .init(status: 204, body: Data()),
            .init(status: 200, body: Data(#"{"inviteCode":"NEXT1234"}"#.utf8)),
            .init(status: 200, body: Data(#"{"events":[{"seq":1,"eventId":"EVENT1","type":"msg","authorMemberId":"01ARZ3NDEKTSV4RRFFQ69G5FAW","epoch":1,"payloadCipher":"Y2lwaGVy","createdAt":1700000000000}],"firstSeq":1,"nextSince":null}"#.utf8)),
            .init(status: 201, body: Data(#"{"seq":2}"#.utf8)),
            .init(status: 200, body: Data(#"{"metaCipher":"bWV0YQ==","metaVersion":1}"#.utf8)),
            .init(status: 201, body: Data(#"{"seq":3,"metaVersion":2}"#.utf8)),
            .init(status: 201, body: Data(#"{"seq":4,"epoch":2}"#.utf8)),
            .init(status: 200, body: Data(#"{"wraps":[{"epoch":1,"wrapped":"d3JhcA==","wrappedBy":"01ARZ3NDEKTSV4RRFFQ69G5FAW","sig":"c2ln"}]}"#.utf8)),
            .init(status: 200, body: Data(#"{"written":["TARGET1"],"skipped":["TARGET2"]}"#.utf8)),
            .init(status: 204, body: Data()),
            .init(status: 200, body: Data(#"{"ticket":"ticket"}"#.utf8)),
            .init(status: 201, body: Data(#"{"id":"REPORT1"}"#.utf8))
        ]

        let created = try await client.create(
            groupId: groupId, memberId: memberId, pubKey: "cHVi", pubKeySig: "c2ln",
            ownerWrap: (wrapped: "d3JhcA==", sig: "c2ln"), metaCipher: "bWV0YQ==", joinPolicy: "accountOnly"
        )
        XCTAssertEqual(created.inviteCode, "JOIN1234")
        let rows = try await client.list()
        XCTAssertEqual(rows[0].groupId, groupId)
        XCTAssertEqual(rows[0].joinedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        let group = try await client.view(id: groupId, memberId: memberId)
        XCTAssertEqual(group.epoch, 1)
        XCTAssertEqual(group.members.first?.pubKey, "cHVi")
        let joined = try await client.join(id: groupId, memberId: memberId, pubKey: "cHVi", pubKeySig: "c2ln", as: "account", inviteCode: "JOIN1234")
        XCTAssertEqual(joined.groupId, groupId)
        let joinedByCode = try await client.joinByCode(memberId: memberId, pubKey: "cHVi", pubKeySig: "c2ln", as: "account", inviteCode: "JOIN1234")
        XCTAssertEqual(joinedByCode.memberId, memberId)
        try await client.leave(id: groupId, memberId: memberId)
        try await client.close(id: groupId, memberId: memberId)
        try await client.kick(id: groupId, memberId: memberId, target: "TARGET1")
        let inviteCode = try await client.resetInvite(id: groupId, memberId: memberId)
        XCTAssertEqual(inviteCode, "NEXT1234")
        let page = try await client.events(id: groupId, memberId: memberId, since: 1, limit: 25)
        XCTAssertEqual(page.firstSeq, 1)
        XCTAssertEqual(page.events.first?.payloadCipher, "Y2lwaGVy")
        let messageSeq = try await client.postMessage(id: groupId, memberId: memberId, eventId: "EVENT1", epoch: 1, payloadCipher: "Y2lwaGVy")
        XCTAssertEqual(messageSeq, 2)
        let metaCipher = try await client.metaCipher(id: groupId, memberId: memberId)
        XCTAssertEqual(metaCipher.metaCipher, "bWV0YQ==")
        let meta = try await client.putMeta(id: groupId, memberId: memberId, eventId: "EVENT2", metaCipher: "bWV0YQ==", joinPolicy: "anonymousAllowed", removeAnonymous: true)
        XCTAssertEqual(meta.metaVersion, 2)
        let rotation = try await client.rotate(id: groupId, memberId: memberId, eventId: "EVENT3", epoch: 2, metaCipher: "bmV3", wraps: [])
        XCTAssertEqual(rotation.epoch, 2)
        let myKeys = try await client.myKeys(id: groupId, memberId: memberId)
        XCTAssertEqual(myKeys.first?.wrapped, "d3JhcA==")
        let keys = try await client.putKeys(id: groupId, memberId: memberId, epoch: 1, wraps: [])
        XCTAssertEqual(keys.written, ["TARGET1"])
        XCTAssertEqual(keys.skipped, ["TARGET2"])
        try await client.requestKey(id: groupId, memberId: memberId)
        let ticket = try await client.wsTicket(id: groupId, memberId: memberId)
        XCTAssertEqual(ticket, "ticket")
        let reportId = try await client.report(id: groupId, memberId: memberId, seq: 2, reason: .spam, excerpt: "summary")
        XCTAssertEqual(reportId, "REPORT1")

        let requests = TestURLProtocol.requests
        XCTAssertEqual(requests.count, 19)
        XCTAssertEqual(requests.map { $0.httpMethod ?? "" }, ["POST", "GET", "GET", "POST", "POST", "POST", "POST", "POST", "POST", "GET", "POST", "GET", "PUT", "POST", "GET", "PUT", "POST", "POST", "POST"])
        XCTAssertEqual(requests.map { $0.url?.path ?? "" }, [
            "/v3/groups", "/v3/groups", "/v3/groups/\(groupId)", "/v3/groups/\(groupId)/join", "/v3/groups/join",
            "/v3/groups/\(groupId)/leave", "/v3/groups/\(groupId)/close", "/v3/groups/\(groupId)/kick",
            "/v3/groups/\(groupId)/invite/reset", "/v3/groups/\(groupId)/events", "/v3/groups/\(groupId)/events",
            "/v3/groups/\(groupId)/meta", "/v3/groups/\(groupId)/meta", "/v3/groups/\(groupId)/rotate",
            "/v3/groups/\(groupId)/keys", "/v3/groups/\(groupId)/keys", "/v3/groups/\(groupId)/request-key",
            "/v3/groups/\(groupId)/ws-ticket", "/v3/groups/\(groupId)/events/2/report"
        ])
        XCTAssertEqual(requests[9].url?.query, "since=1&limit=25")
        for index in [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18] {
            XCTAssertEqual(requests[index].value(forHTTPHeaderField: "X-Group-Member-Id"), memberId)
        }
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "X-Group-Member-Id"))
        XCTAssertEqual(Set(try body(0).keys), Set(["groupId", "memberId", "pubKey", "pubKeySig", "ownerWrap", "metaCipher", "joinPolicy"]))
        let ownerWrap = try body(0)["ownerWrap"] as? [String: Any]
        XCTAssertEqual(ownerWrap?["wrapped"] as? String, "d3JhcA==")
        XCTAssertEqual(try body(3)["as"] as? String, "account")
        XCTAssertEqual(try body(3)["memberId"] as? String, memberId)
        XCTAssertEqual(Set(try body(7).keys), Set(["memberId"]))
        XCTAssertEqual(try body(7)["memberId"] as? String, "TARGET1")
        XCTAssertEqual(Set(try body(10).keys), Set(["eventId", "epoch", "payloadCipher"]))
        XCTAssertEqual(Set(try body(12).keys), Set(["eventId", "metaCipher", "joinPolicy", "removeAnonymous"]))
        XCTAssertEqual(Set(try body(13).keys), Set(["eventId", "epoch", "metaCipher", "wraps"]))
        XCTAssertEqual(Set(try body(15).keys), Set(["epoch", "wraps"]))
        XCTAssertEqual(Set(try body(18).keys), Set(["reason", "excerpt"]))
        XCTAssertEqual(try body(0)["metaCipher"] as? String, "bWV0YQ==")
        XCTAssertEqual(try body(10)["payloadCipher"] as? String, "Y2lwaGVy")
        XCTAssertEqual(try body(12)["metaCipher"] as? String, "bWV0YQ==")
    }

    func testInvalidGroupIdsAreRejectedBeforeRequest() async {
        for invalidId in ["GROUP/ID", "../GROUP"] {
            do {
                _ = try await client.view(id: invalidId, memberId: memberId)
                XCTFail("expected .badId")
            } catch {
                XCTAssertEqual(error as? GroupError, .badId)
            }
        }
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    func testWorkerErrorsMapToGroupErrors() async {
        let failures: [(Int, String, GroupError)] = [
            (403, "awaiting_key", .awaitingKey),
            (403, "not_member", .notMember),
            (409, "stale_epoch", .staleEpoch),
            (409, "members_changed", .membersChanged),
            (409, "group_full_members", .membersFull),
            (409, "group_limit", .groupLimit),
            (400, "bad_sig", .badSignature),
            (413, "too_large", .tooLarge),
            (429, "rate_limited", .transient("rate_limited")),
            (503, "busy", .transient("http_503")),
            (404, "not_found", .notFound)
        ]

        for (status, code, expected) in failures {
            TestURLProtocol.queue = [.init(status: status, body: Data(#"{"error":"\#(code)"}"#.utf8))]
            do {
                _ = try await client.view(id: groupId, memberId: memberId)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? GroupError, expected)
            }
        }
    }
}

final class TestURLProtocol: URLProtocol {
    struct Stub { let status: Int; let body: Data }
    static var queue: [Stub] = []
    static var requests: [URLRequest] = []

    static func reset() { queue = []; requests = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(Self.materialized(request))
        let stub = Self.queue.isEmpty ? Stub(status: 500, body: Data()) : Self.queue.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func materialized(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        var copy = request
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        copy.httpBody = data
        return copy
    }
}
