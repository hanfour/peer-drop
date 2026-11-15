import XCTest
import PeerDropSecurity
@testable import PeerDropTransport

/// Runs only against a real local Worker (`Scripts/mailbox-pow-e2e.sh` sets the environment).
final class MailboxPoWE2ETests: XCTestCase {

    private func workerURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["MAILBOX_E2E_URL"], let url = URL(string: raw) else {
            throw XCTSkip("MAILBOX_E2E_URL not set")
        }
        return url
    }

    func test_currentClientDeliversToTheWorker() async throws {
        let client = MailboxClient(baseURL: try workerURL())
        try await client.sendMessage(to: "e2e\(Int.random(in: 100_000...999_999))", ciphertext: Data("current client".utf8))
    }

    func test_legacyFormatMatchesTheExpectedPolicy() async throws {
        let base = try workerURL()
        let expectation = ProcessInfo.processInfo.environment["MAILBOX_E2E_LEGACY"] ?? "accepted"
        let challenge = UUID().uuidString
        let maybeProof = await ProofOfWork.generate(challenge: challenge)
        let proof = try XCTUnwrap(maybeProof)
        var request = URLRequest(url: base.appendingPathComponent("v2/messages/e2e\(Int.random(in: 100_000...999_999))"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SendMessageRequest(
            ciphertext: Data("old client".utf8).base64EncodedString(),
            pow: ProofOfWorkToken(challenge: challenge, proof: proof)))
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        XCTAssertEqual(status, expectation == "accepted" ? 201 : 403)
    }
}
