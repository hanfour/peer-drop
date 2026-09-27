import XCTest
import CryptoKit
@testable import peerdrop_cli
@testable import PeerDropCore
@testable import PeerDropProtocol
@testable import PeerDropSecurity

/// Short-term mitigation for #173 (SAS collision by key grinding), in the CLI:
/// (a) only one first-trust pairing at a time — a second new peer that reaches
///     first-trust while a prompt is open is rejected and disconnected;
/// (b) the prompt also shows the full SHA-256 fingerprint of the key the peer
///     actually used in the handshake.
@MainActor
final class FirstTrustGuardTests: XCTestCase {

    private var cm: ConnectionManager!
    private var logged: [String] = []

    override func setUp() async throws {
        cm = ConnectionManager()
        logged = []
    }

    private func firstTrustConnection(_ peerID: String, peer: EphemeralIdentity, helloKey: Data? = nil) async throws -> PeerConnection {
        let conn = try await makeSecuredConnection(
            peerID: peerID, peer: peer, helloKey: helloKey ?? peer.publicKey.rawRepresentation)
        conn.setPinningVerdict(.firstTrust)
        cm._setConnectionForTesting(peerID: peerID, conn)
        return conn
    }

    private func pending(for conn: PeerConnection, name: String = "phone") -> PendingFirstContact {
        PendingFirstContact(
            fingerprint: ConnectionManager.computeFingerprint(of: conn.handshakePeerIdentityKey!),
            senderDisplayName: name,
            senderIdentityKey: conn.peerIdentity.identityPublicKey!,
            sas: "123 456")
    }

    private func makeGuard() -> FirstTrustGuard {
        FirstTrustGuard(connectionManager: cm, log: { [unowned self] in self.logged.append($0) })
    }

    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
        let hop = expectation(description: "main queue")
        DispatchQueue.main.async { hop.fulfill() }
        await fulfillment(of: [hop], timeout: 2)
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: (a) one pairing at a time

    func test_secondFirstTrustPeer_whilePromptOpen_isRejectedAndDisconnected() async throws {
        let first = try await firstTrustConnection("A", peer: EphemeralIdentity())
        cm.pendingLocalFirstTrust = pending(for: first)
        let second = try await firstTrustConnection("B", peer: EphemeralIdentity())
        _ = second

        let guardian = makeGuard()
        guardian.evaluate("B")
        await settle()

        XCTAssertNil(cm.connection(for: "B"), "second new peer must be disconnected")
        XCTAssertNotNil(cm.connection(for: "A"), "the peer the prompt is about stays")
        XCTAssertTrue(logged.contains { $0.contains("rejected") }, "operator must see a line: \(logged)")
    }

    func test_secondPeer_isRejectedWhenItsVerdictBecomesFirstTrust() async throws {
        let first = try await firstTrustConnection("A", peer: EphemeralIdentity())
        cm.pendingLocalFirstTrust = pending(for: first)
        let second = try await makeSecuredConnection(
            peerID: "B", peer: EphemeralIdentity(), helloKey: nil)
        cm._setConnectionForTesting(peerID: "B", second)

        let guardian = makeGuard()
        guardian.watch("B")
        second.setPinningVerdict(.firstTrust)
        await settle()

        XCTAssertNil(cm.connection(for: "B"))
    }

    func test_promptOwner_isNotRejected() async throws {
        let first = try await firstTrustConnection("A", peer: EphemeralIdentity())
        cm.pendingLocalFirstTrust = pending(for: first)

        makeGuard().evaluate("A")
        await settle()

        XCTAssertNotNil(cm.connection(for: "A"))
        XCTAssertEqual(logged, [])
    }

    func test_verifiedPeer_isNotRejectedWhilePromptOpen() async throws {
        let first = try await firstTrustConnection("A", peer: EphemeralIdentity())
        cm.pendingLocalFirstTrust = pending(for: first)
        let verified = try await firstTrustConnection("C", peer: EphemeralIdentity())
        verified.setPinningVerdict(.matched)

        makeGuard().evaluate("C")
        await settle()

        XCTAssertNotNil(cm.connection(for: "C"))
    }

    func test_noPromptOpen_nothingIsRejected() async throws {
        _ = try await firstTrustConnection("B", peer: EphemeralIdentity())

        makeGuard().evaluate("B")
        await settle()

        XCTAssertNotNil(cm.connection(for: "B"))
    }

    // MARK: (b) full fingerprint of the HANDSHAKE key

    func test_keyFingerprint_isFullGroupedSHA256Hex() {
        let key = Data(repeating: 0x42, count: 32)
        let hex = SHA256.hash(data: key).map { String(format: "%02X", $0) }.joined()
        let fp = FirstTrustGuard.keyFingerprint(key)
        XCTAssertEqual(fp.replacingOccurrences(of: " ", with: ""), hex)
        XCTAssertEqual(fp.split(separator: " ").count, 16)
        XCTAssertTrue(fp.split(separator: " ").allSatisfy { $0.count == 4 })
    }

    func test_promptFingerprint_isDerivedFromHandshakeKey_notHelloKey() async throws {
        let helloKey = EphemeralIdentity().publicKey.rawRepresentation
        let actual = EphemeralIdentity()
        let conn = try await firstTrustConnection("A", peer: actual, helloKey: helloKey)
        let handshakeKey = actual.publicKey.rawRepresentation
        XCTAssertNotEqual(handshakeKey, helloKey)

        let lines = FirstTrustGuard.promptLines(for: pending(for: conn), cm: cm)
        let text = lines.joined(separator: "\n")
        let expected = FirstTrustGuard.keyFingerprint(handshakeKey).split(separator: " ")
        let wrong = FirstTrustGuard.keyFingerprint(helloKey).split(separator: " ")
        guard expected.count == 16, wrong.count == 16 else {
            return XCTFail("fingerprint must be 16 groups of 4 hex chars")
        }
        // Printed on two lines of 8 groups.
        XCTAssertTrue(text.contains(expected[0..<8].joined(separator: " ")), text)
        XCTAssertTrue(text.contains(expected[8..<16].joined(separator: " ")), text)
        XCTAssertFalse(text.contains(wrong[0..<8].joined(separator: " ")), text)
        XCTAssertTrue(text.contains("SAS: 123 456"))
        XCTAssertTrue(text.lowercased().contains("fingerprint shown on the phone"), text)
    }
}
