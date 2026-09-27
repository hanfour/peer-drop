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

    // MARK: Final review, item 1: rejection message

    func test_rejectionMessage_showsRejectedFingerprint_andDoesNotSayAnswerN() async throws {
        let first = try await firstTrustConnection("A", peer: EphemeralIdentity())
        cm.pendingLocalFirstTrust = pending(for: first)
        let intruder = EphemeralIdentity()
        _ = try await firstTrustConnection("B", peer: intruder)

        makeGuard().evaluate("B")
        await settle()

        let text = logged.joined(separator: "\n")
        XCTAssertTrue(text.contains(FirstTrustGuard.phoneFingerprint(intruder.publicKey.rawRepresentation)), text)
        XCTAssertTrue(text.contains("Security"), text)
        XCTAssertFalse(text.lowercased().contains("answer n"), text)
    }

    // MARK: Final review, item 1: "n" dismisses without blocking

    /// Adds a throwaway contact to the manager's store and removes it afterwards.
    private func withContact(key: Data, _ body: () async throws -> Void) async rethrows {
        let contact = TrustedContact(displayName: "t", identityPublicKey: key, trustLevel: .unknown)
        cm.trustedContactStore.add(contact)
        defer { cm.trustedContactStore.remove(contact.id) }
        try await body()
    }

    func test_answerNo_dismissesAndDisconnects_withoutBlocking() async throws {
        let peer = EphemeralIdentity()
        let conn = try await firstTrustConnection("A", peer: peer)
        let prompt = pending(for: conn)
        cm.pendingLocalFirstTrust = prompt
        try await withContact(key: peer.publicKey.rawRepresentation) {
            makeGuard().handleAnswer("n", for: prompt)
            await settle()

            XCTAssertNil(cm.pendingLocalFirstTrust)
            XCTAssertNil(cm.connection(for: "A"), "the unapproved device is disconnected")
            let stored = cm.trustedContactStore.find(byPublicKey: peer.publicKey.rawRepresentation)
            XCTAssertEqual(stored?.isBlocked, false, "\"n\" must not block the key")
        }
    }

    func test_emptyAnswer_isTreatedAsNo_withoutBlocking() async throws {
        let peer = EphemeralIdentity()
        let conn = try await firstTrustConnection("A", peer: peer)
        let prompt = pending(for: conn)
        cm.pendingLocalFirstTrust = prompt
        try await withContact(key: peer.publicKey.rawRepresentation) {
            makeGuard().handleAnswer(nil, for: prompt)
            await settle()
            XCTAssertNil(cm.pendingLocalFirstTrust)
            XCTAssertEqual(cm.trustedContactStore.find(byPublicKey: peer.publicKey.rawRepresentation)?.isBlocked, false)
        }
    }

    func test_answerYes_approves() async throws {
        let peer = EphemeralIdentity()
        let conn = try await firstTrustConnection("A", peer: peer)
        let prompt = pending(for: conn)
        cm.pendingLocalFirstTrust = prompt
        try await withContact(key: peer.publicKey.rawRepresentation) {
            makeGuard().handleAnswer("y", for: prompt)
            XCTAssertEqual(conn.pinningVerdict, .matched)
            XCTAssertNil(cm.pendingLocalFirstTrust)
        }
    }

    func test_answerForClosedPrompt_isIgnored() async throws {
        let conn = try await firstTrustConnection("A", peer: EphemeralIdentity())
        let prompt = pending(for: conn)
        cm.pendingLocalFirstTrust = nil          // already closed

        makeGuard().handleAnswer("y", for: prompt)

        XCTAssertEqual(conn.pinningVerdict, .firstTrust)
        XCTAssertTrue(logged.contains { $0.contains("ignored") }, "\(logged)")
    }

    // MARK: Final review, item 3: stale prompt when its device leaves

    func test_promptOwnerDisconnects_promptIsClosed() async throws {
        let conn = try await firstTrustConnection("A", peer: EphemeralIdentity())
        cm.pendingLocalFirstTrust = pending(for: conn)
        let guardian = makeGuard()

        await cm.disconnect(from: "A")
        guardian.stopWatching("A")

        XCTAssertNil(cm.pendingLocalFirstTrust)
        XCTAssertTrue(logged.contains { $0.contains("left") }, "\(logged)")
    }

    func test_otherPeerDisconnects_promptStays() async throws {
        let conn = try await firstTrustConnection("A", peer: EphemeralIdentity())
        _ = try await firstTrustConnection("B", peer: EphemeralIdentity())
        let prompt = pending(for: conn)
        cm.pendingLocalFirstTrust = prompt
        let guardian = makeGuard()

        await cm.disconnect(from: "B")
        guardian.stopWatching("B")

        XCTAssertEqual(cm.pendingLocalFirstTrust, prompt)
    }

    // MARK: Final review, item 2: phone-format fingerprints

    func test_phoneFingerprint_matchesThePhonesAlgorithm() {
        let key = EphemeralIdentity().publicKey.rawRepresentation
        let expected = TrustedContact(displayName: "x", identityPublicKey: key, trustLevel: .unknown).keyFingerprint
        XCTAssertEqual(FirstTrustGuard.phoneFingerprint(key), expected)
        XCTAssertEqual(FirstTrustGuard.phoneFingerprint(key).split(separator: " ").count, 5)
    }

    func test_prompt_showsHandshakeKeyPhoneFingerprint_notHelloKey_andOwnFingerprint() async throws {
        let helloKey = EphemeralIdentity().publicKey.rawRepresentation
        let actual = EphemeralIdentity()
        let conn = try await firstTrustConnection("A", peer: actual, helloKey: helloKey)
        let handshakeKey = actual.publicKey.rawRepresentation
        XCTAssertNotEqual(handshakeKey, helloKey)

        let lines = FirstTrustGuard.promptLines(for: pending(for: conn), cm: cm, ownFingerprint: "AAAA BBBB CCCC DDDD EEEE")
        let text = lines.joined(separator: "\n")
        let expected = FirstTrustGuard.phoneFingerprint(handshakeKey)
        XCTAssertTrue(text.contains("On the phone, open Security (the shield screen) and check that its own fingerprint equals: \(expected)"), text)
        XCTAssertFalse(text.contains(FirstTrustGuard.phoneFingerprint(helloKey)), text)
        XCTAssertTrue(text.contains("The 6-digit code alone can be forged"), text)
        XCTAssertTrue(text.contains("pairing sheet should show: AAAA BBBB CCCC DDDD EEEE"), text)
        XCTAssertTrue(text.contains("SAS: 123 456"))
    }
}
