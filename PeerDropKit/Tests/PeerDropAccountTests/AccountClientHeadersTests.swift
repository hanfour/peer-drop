import Foundation
import XCTest
@testable import PeerDropAccount

final class AccountClientHeadersTests: XCTestCase {
    private var client: AccountClient!

    override func setUp() {
        TestURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        client = AccountClient(
            baseURL: URL(string: "https://worker.test")!,
            session: URLSession(configuration: configuration),
            authProvider: { $0.setValue("Bearer t", forHTTPHeaderField: "Authorization") },
            tokenInvalidator: {}
        )
    }

    func testRequestAddsCustomHeadersAndPreservesAuthHeader() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"mailboxId":"abc"}"#.utf8))]

        _ = try await client.request(
            "GET", "v3/account/me", body: Optional<EmptyBody>.none,
            headers: ["X-Group-Member-Id": "MEMBER1"]
        ) as MeResponse

        XCTAssertEqual(TestURLProtocol.requests[0].value(forHTTPHeaderField: "X-Group-Member-Id"), "MEMBER1")
        XCTAssertEqual(TestURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testRequestWithoutCustomHeadersPreservesExistingBehavior() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"mailboxId":"abc"}"#.utf8))]

        _ = try await client.request("GET", "v3/account/me", body: Optional<EmptyBody>.none) as MeResponse

        XCTAssertNil(TestURLProtocol.requests[0].value(forHTTPHeaderField: "X-Group-Member-Id"))
        XCTAssertEqual(TestURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }
}
