import XCTest
import PeerDropSecurity
@testable import PeerDropTransport

final class MailboxClientPoWTests: XCTestCase {

    private final class StubProtocol: URLProtocol {
        struct Reply { var status: Int; var body: Data }
        nonisolated(unsafe) static var challengeReply = Reply(status: 404, body: Data())
        nonisolated(unsafe) static var deliverReply = Reply(status: 201, body: Data("{}".utf8))
        nonisolated(unsafe) static var requests: [(path: String, body: Data?)] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url?.path ?? ""
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                body = data
            }
            Self.requests.append((path, body))
            let reply = path.hasSuffix("/challenge") ? Self.challengeReply : Self.deliverReply
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> MailboxClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return MailboxClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: config))
    }

    private func deliveredPoW() throws -> (ciphertext: String, challenge: String, proof: UInt64) {
        let delivery = try XCTUnwrap(StubProtocol.requests.last { !$0.path.hasSuffix("/challenge") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(delivery.body)) as? [String: Any])
        let pow = try XCTUnwrap(json["pow"] as? [String: Any])
        return (json["ciphertext"] as! String, pow["challenge"] as! String, (pow["proof"] as! NSNumber).uint64Value)
    }

    override func setUp() {
        super.setUp()
        StubProtocol.requests = []
        StubProtocol.deliverReply = .init(status: 201, body: Data("{}".utf8))
    }

    func test_usesServerIssuedChallengeAndBindsProofToMailboxAndCiphertext() async throws {
        StubProtocol.challengeReply = .init(status: 201, body: Data(#"{"challenge":"server-issued-challenge","difficulty":8,"expiresInSeconds":300}"#.utf8))
        try await makeClient().sendMessage(to: "mbx123", ciphertext: Data("hello".utf8))

        let sent = try deliveredPoW()
        XCTAssertEqual(sent.challenge, "server-issued-challenge")
        XCTAssertEqual(sent.ciphertext, Data("hello".utf8).base64EncodedString())
        XCTAssertTrue(MailboxProofOfWork.verify(challenge: sent.challenge, mailboxId: "mbx123", ciphertext: sent.ciphertext, proof: sent.proof, difficulty: 8))
        XCTAssertFalse(MailboxProofOfWork.verify(challenge: sent.challenge, mailboxId: "other", ciphertext: sent.ciphertext, proof: sent.proof, difficulty: 24),
                       "a proof for one mailbox must not satisfy a much harder check for another")
        XCTAssertEqual(StubProtocol.requests.map(\.path), ["/v2/messages/mbx123/challenge", "/v2/messages/mbx123"])
    }

    func test_fallsBackToLegacyChallengeWhenWorkerHasNoChallengeEndpoint() async throws {
        StubProtocol.challengeReply = .init(status: 404, body: Data())
        try await makeClient().sendMessage(to: "mbx456", ciphertext: Data("legacy".utf8))

        let sent = try deliveredPoW()
        XCTAssertNotNil(UUID(uuidString: sent.challenge), "legacy challenge is a client-chosen UUID")
        XCTAssertTrue(ProofOfWork.verify(challenge: sent.challenge, proof: sent.proof, difficulty: 16))
    }

    func test_doesNotSendWhenChallengeRequestFailsWithAnotherError() async {
        StubProtocol.challengeReply = .init(status: 500, body: Data())
        do {
            try await makeClient().sendMessage(to: "mbx789", ciphertext: Data("x".utf8))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(StubProtocol.requests.map(\.path), ["/v2/messages/mbx789/challenge"])
        }
    }

    func test_boundProofRejectsAnotherCiphertext() throws {
        let proof = try XCTUnwrap(MailboxProofOfWork.generate(challenge: "c", mailboxId: "m", ciphertext: "ct-a", difficulty: 12))
        XCTAssertTrue(MailboxProofOfWork.verify(challenge: "c", mailboxId: "m", ciphertext: "ct-a", proof: proof, difficulty: 12))
        XCTAssertFalse(MailboxProofOfWork.verify(challenge: "c", mailboxId: "m", ciphertext: "ct-b", proof: proof, difficulty: 12))
    }
}
