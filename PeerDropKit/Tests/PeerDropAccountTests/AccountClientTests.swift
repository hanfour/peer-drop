import XCTest
@testable import PeerDropAccount

final class AccountClientTests: XCTestCase {
    private var client: AccountClient!
    private var authCalls = 0
    private var invalidations = 0

    override func setUp() {
        TestURLProtocol.reset(); authCalls = 0; invalidations = 0
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TestURLProtocol.self]
        client = AccountClient(
            baseURL: URL(string: "https://worker.test")!,
            session: URLSession(configuration: cfg),
            authProvider: { req in self.authCalls += 1; req.setValue("Bearer t\(self.authCalls)", forHTTPHeaderField: "Authorization") },
            tokenInvalidator: { self.invalidations += 1 })
    }

    func testLookupDecodesEntryAndSendsBearer() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":"mochi","identityKey":"AAAA","signingKey":"AAAA","mailboxId":"abc"}"#.utf8))]
        let entry = try await client.lookup(handle: "7k3m-q2zd", includeBundle: false)
        XCTAssertEqual(entry?.accountId.raw, "7K3MQ2ZD")
        XCTAssertEqual(entry?.nickname, "mochi")
        let req = TestURLProtocol.requests[0]
        XCTAssertEqual(req.url?.path, "/v3/directory/7k3m-q2zd")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer t1")
    }
    func testLookup404ReturnsNil() async throws {
        TestURLProtocol.queue = [.init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))]
        // XCTAssertNil's `@autoclosure` parameter doesn't support `async`
        // (a long-standing XCTest/Swift limitation), so the awaited value
        // is bound to a local first rather than inlined into the macro.
        let entry = try await client.lookup(handle: "nobody", includeBundle: false)
        XCTAssertNil(entry)
    }
    func test401RetriesOnceAfterInvalidatingToken() async throws {
        TestURLProtocol.queue = [.init(status: 401, body: Data()), .init(status: 200, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"mailboxId":"abc"}"#.utf8))]
        let me = try await client.me()
        XCTAssertEqual(me.accountId.raw, "7K3MQ2ZD")
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(TestURLProtocol.requests.count, 2)
        XCTAssertEqual(TestURLProtocol.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer t2")
    }
    func testErrorMapping() async {
        TestURLProtocol.queue = [.init(status: 409, body: Data(#"{"error":"nickname_taken"}"#.utf8))]
        await XCTAssertThrowsErrorAsync(try await client.setNickname("x_y_z")) { XCTAssertEqual($0 as? AccountClientError, .conflict("nickname_taken")) }
        TestURLProtocol.queue = [.init(status: 429, body: Data(#"{"error":"rate_limited"}"#.utf8))]
        await XCTAssertThrowsErrorAsync(try await client.setNickname("x_y_z")) { XCTAssertEqual($0 as? AccountClientError, .rateLimited) }
        TestURLProtocol.queue = [.init(status: 400, body: Data(#"{"error":"reserved"}"#.utf8))]
        await XCTAssertThrowsErrorAsync(try await client.setNickname("admin")) { XCTAssertEqual($0 as? AccountClientError, .invalid("reserved")) }
        TestURLProtocol.queue = [.init(status: 401, body: Data()), .init(status: 401, body: Data())]
        await XCTAssertThrowsErrorAsync(try await client.me()) { XCTAssertEqual($0 as? AccountClientError, .unauthorized) }
    }
    func testRegisterEncodesBase64AndDecodesResponse() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"token":"tok","expiresInSeconds":900}"#.utf8))]
        let req = RegisterRequest(deviceId: "dev-1", platform: "ios", identityKey: Data(repeating: 1, count: 32), signingKey: Data(repeating: 2, count: 32), mailboxId: "m", mailboxToken: "mbx-tok", nonce: Data(repeating: 3, count: 32), signature: Data(repeating: 4, count: 64))
        let resp = try await client.register(req)
        XCTAssertEqual(resp.token, "tok")
        let sent = try JSONSerialization.jsonObject(with: TestURLProtocol.requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(sent?["signingKey"] as? String, Data(repeating: 2, count: 32).base64EncodedString())
        XCTAssertEqual(sent?["mailboxToken"] as? String, "mbx-tok")
    }
    func testSetNicknameNilSendsJsonNull() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"nickname":null}"#.utf8))]
        let result = try await client.setNickname(nil)
        XCTAssertNil(result)
        let sent = try JSONSerialization.jsonObject(with: TestURLProtocol.requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertNotNil(sent?["nickname"])
        XCTAssertTrue(sent?["nickname"] is NSNull)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expr: @autoclosure () async throws -> T, _ handler: (Error) -> Void) async {
    do { _ = try await expr(); XCTFail("expected error") } catch { handler(error) }
}
