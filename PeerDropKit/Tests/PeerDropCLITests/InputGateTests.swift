import XCTest
import CryptoKit
@testable import peerdrop_cli
@testable import PeerDropCore
@testable import PeerDropProtocol
@testable import PeerDropSecurity
@testable import PeerDropTransport

// MARK: - Fakes

/// Records every line the session would have written to the PTY.
final class RecordingBridge: MessageBridge {
    var onMessage: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    private let lock = NSLock()
    private var _sent: [String] = []
    var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
    func start() {}
    func send(_ line: String) { lock.lock(); _sent.append(line); lock.unlock() }
    func terminate() {}
}

/// In-memory transport: swallows sends, never receives.
final class NullTransport: TransportProtocol {
    var isReady: Bool { true }
    var onStateChange: ((TransportState) -> Void)?
    func send(_ message: PeerMessage) async throws {}
    func receive() async throws -> PeerMessage {
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        throw CancellationError()
    }
    func close() {}
}

/// A channel identity backed by a fresh in-memory key (no keychain).
struct EphemeralIdentity: LocalChannelIdentity {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }
    func deriveSharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
        try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }
}

// MARK: - Pure gate

final class InputGateTests: XCTestCase {

    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)

    private func facts(
        secured: Bool = true,
        handshake: Data? = nil,
        hello: Data? = nil,
        verdict: PeerConnection.PinningVerdict = .matched,
        trusted: Bool = true
    ) -> InputAuthFacts {
        InputAuthFacts(
            isSecured: secured,
            handshakeIdentityKey: handshake ?? keyA,
            helloIdentityKey: hello ?? keyA,
            pinningVerdict: verdict,
            handshakeKeyTrusted: trusted
        )
    }

    func test_noConnection_isNotForwarded() {
        XCTAssertFalse(InputGate.shouldForwardInput(nil))
    }

    func test_unsecuredConnection_isNotForwarded() {
        XCTAssertFalse(InputGate.shouldForwardInput(facts(secured: false)))
    }

    func test_missingHandshakeKey_isNotForwarded() {
        var f = facts()
        f.handshakeIdentityKey = nil
        XCTAssertFalse(InputGate.shouldForwardInput(f))
    }

    func test_missingHelloKey_isNotForwarded() {
        var f = facts()
        f.helloIdentityKey = nil
        XCTAssertFalse(InputGate.shouldForwardInput(f))
    }

    func test_handshakeKeyDiffersFromHelloKey_isNotForwarded() {
        XCTAssertFalse(InputGate.shouldForwardInput(facts(handshake: keyA, hello: keyB)))
    }

    func test_firstTrustPendingSAS_isNotForwarded() {
        XCTAssertFalse(InputGate.shouldForwardInput(facts(verdict: .firstTrust)))
    }

    func test_notChecked_isNotForwarded() {
        XCTAssertFalse(InputGate.shouldForwardInput(facts(verdict: .notChecked)))
    }

    func test_mismatch_isNotForwarded() {
        XCTAssertFalse(InputGate.shouldForwardInput(facts(verdict: .mismatch(stored: "x", received: "y"))))
    }

    func test_handshakeKeyNotTrustedInStore_isNotForwarded() {
        XCTAssertFalse(InputGate.shouldForwardInput(facts(trusted: false)))
    }

    func test_securedMatchingVerifiedPeer_isForwarded() {
        XCTAssertTrue(InputGate.shouldForwardInput(facts()))
    }

    // MARK: - Connection-accept decision

    func test_enroll_isNotAcceptedAsTrusted() {
        let action = AgentSession.connectionAction(for: .enroll, peerSupportsSecureChannel: true)
        XCTAssertEqual(action, .acceptPendingSAS)
        XCTAssertNotEqual(action, .acceptTrusted)
    }

    func test_enroll_withoutSecureChannel_isRejected() {
        XCTAssertEqual(AgentSession.connectionAction(for: .enroll, peerSupportsSecureChannel: false), .reject)
    }

    func test_autoAccept_withoutSecureChannel_isRejected() {
        XCTAssertEqual(AgentSession.connectionAction(for: .autoAccept, peerSupportsSecureChannel: false), .reject)
    }

    func test_autoAccept_withSecureChannel_isAccepted() {
        XCTAssertEqual(AgentSession.connectionAction(for: .autoAccept, peerSupportsSecureChannel: true), .acceptTrusted)
    }

    func test_reject_isRejected() {
        XCTAssertEqual(AgentSession.connectionAction(for: .reject, peerSupportsSecureChannel: true), .reject)
    }
}

// MARK: - Facts built from a real ConnectionManager / PeerConnection

final class InputGateFactsTests: XCTestCase {

    @MainActor
    private func securedConnection(
        peerID: String,
        peer: EphemeralIdentity,
        helloKey: Data?
    ) async throws -> PeerConnection {
        let me = EphemeralIdentity()
        let conn = PeerConnection(
            peerID: peerID,
            transport: NullTransport(),
            peerIdentity: PeerIdentity(id: peerID, displayName: "phone",
                                       identityPublicKey: helloKey,
                                       supportsSecureChannel: true),
            localIdentity: PeerIdentity(id: "cli", displayName: "cli")
        )
        let (bundle, _) = LocalSecureChannel.prepareHandshake(identity: peer)
        let msg = try PeerMessage.secureHandshake(bundle: bundle, senderID: peerID)
        try await conn.handleIncomingSecureHandshake(msg, identity: me)
        XCTAssertEqual(conn.secureChannelState, .secured)
        return conn
    }

    @MainActor
    func test_facts_noConnection_isNil() {
        let cm = ConnectionManager()
        XCTAssertNil(InputGate.facts(for: "ghost", cm: cm, store: .inMemory()))
    }

    @MainActor
    func test_facts_plaintextConnection_isNotSecured() {
        let cm = ConnectionManager()
        let conn = PeerConnection(
            peerID: "p1", transport: NullTransport(),
            peerIdentity: PeerIdentity(id: "p1", displayName: "old", supportsSecureChannel: false),
            localIdentity: PeerIdentity(id: "cli", displayName: "cli"))
        conn.setPinningVerdict(.matched)
        cm._setConnectionForTesting(peerID: "p1", conn)
        let f = InputGate.facts(for: "p1", cm: cm, store: .inMemory())
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.isSecured, false)
        XCTAssertFalse(InputGate.shouldForwardInput(f))
    }

    @MainActor
    func test_facts_securedVerifiedPeer_isForwarded() async throws {
        let cm = ConnectionManager()
        let store = TrustedContactStore.inMemory()
        let peer = EphemeralIdentity()
        let peerKey = peer.publicKey.rawRepresentation
        store.add(TrustedContact(displayName: "phone", identityPublicKey: peerKey, trustLevel: .linked))
        let conn = try await securedConnection(peerID: "p2", peer: peer, helloKey: peerKey)
        conn.setPinningVerdict(.matched)
        cm._setConnectionForTesting(peerID: "p2", conn)

        let f = InputGate.facts(for: "p2", cm: cm, store: store)
        XCTAssertEqual(f?.handshakeIdentityKey, peerKey)
        XCTAssertTrue(InputGate.shouldForwardInput(f))
    }

    /// Hello claims a verified contact's key, but the handshake is done with a
    /// different key: the verdict (computed off the hello key) says `.matched`,
    /// yet the gate must refuse.
    @MainActor
    func test_facts_helloClaimsVerifiedKey_handshakeUsesOther_isNotForwarded() async throws {
        let cm = ConnectionManager()
        let store = TrustedContactStore.inMemory()
        let victimKey = EphemeralIdentity().publicKey.rawRepresentation
        store.add(TrustedContact(displayName: "victim", identityPublicKey: victimKey, trustLevel: .verified))
        let attacker = EphemeralIdentity()
        let conn = try await securedConnection(peerID: "p3", peer: attacker, helloKey: victimKey)
        conn.setPinningVerdict(.matched)
        cm._setConnectionForTesting(peerID: "p3", conn)

        XCTAssertFalse(InputGate.shouldForwardInput(InputGate.facts(for: "p3", cm: cm, store: store)))
    }

    @MainActor
    func test_facts_unknownTrustContact_isNotForwarded() async throws {
        let cm = ConnectionManager()
        let store = TrustedContactStore.inMemory()
        let peer = EphemeralIdentity()
        let peerKey = peer.publicKey.rawRepresentation
        store.add(TrustedContact(displayName: "new", identityPublicKey: peerKey, trustLevel: .unknown))
        let conn = try await securedConnection(peerID: "p4", peer: peer, helloKey: peerKey)
        conn.setPinningVerdict(.firstTrust)
        cm._setConnectionForTesting(peerID: "p4", conn)

        XCTAssertFalse(InputGate.shouldForwardInput(InputGate.facts(for: "p4", cm: cm, store: store)))
    }
}

// MARK: - AgentSession wiring

final class AgentSessionInputWiringTests: XCTestCase {

    private func textMessage(_ text: String, from peerID: String) throws -> PeerMessage {
        try PeerMessage.textMessage(TextMessagePayload(text: text, senderName: "x"), senderID: peerID)
    }

    /// No connection for the sender → nothing written to the PTY, peer not attached.
    @MainActor
    func test_textFromUnknownPeer_isDropped() throws {
        let cm = ConnectionManager()
        let bridge = RecordingBridge()
        let session = AgentSession(bridge: bridge, connectionManager: cm, store: .inMemory())
        session.wire()

        cm.dispatchTextForTesting(try textMessage("rm -rf ~", from: "evil"), from: "evil")

        XCTAssertEqual(bridge.sent, [])
        XCTAssertFalse(session.attachedPeerIDs.contains("evil"))
    }

    @MainActor
    func test_textFromUnauthorizedPeer_isDropped() throws {
        let cm = ConnectionManager()
        let bridge = RecordingBridge()
        let session = AgentSession(bridge: bridge, connectionManager: cm, store: .inMemory(),
                                   isAuthorized: { _ in false })
        session.wire()

        cm.dispatchTextForTesting(try textMessage("id", from: "p1"), from: "p1")

        XCTAssertEqual(bridge.sent, [])
        XCTAssertFalse(session.attachedPeerIDs.contains("p1"))
    }

    @MainActor
    func test_textFromAuthorizedPeer_isForwarded() throws {
        let cm = ConnectionManager()
        let bridge = RecordingBridge()
        let session = AgentSession(bridge: bridge, connectionManager: cm, store: .inMemory(),
                                   isAuthorized: { $0 == "good" })
        session.wire()

        cm.dispatchTextForTesting(try textMessage("ls", from: "good"), from: "good")
        cm.dispatchTextForTesting(try textMessage("whoami", from: "bad"), from: "bad")

        XCTAssertEqual(bridge.sent, ["ls"])
        XCTAssertTrue(session.attachedPeerIDs.contains("good"))
        XCTAssertFalse(session.attachedPeerIDs.contains("bad"))
    }

    /// Input sent before SAS approval is dropped, not buffered and replayed once
    /// the peer becomes authorized.
    @MainActor
    func test_inputBeforeApproval_isNotReplayedAfterApproval() throws {
        let cm = ConnectionManager()
        let bridge = RecordingBridge()
        var approved = false
        let session = AgentSession(bridge: bridge, connectionManager: cm, store: .inMemory(),
                                   isAuthorized: { _ in approved })
        session.wire()

        cm.dispatchTextForTesting(try textMessage("early", from: "p"), from: "p")
        approved = true
        cm.dispatchTextForTesting(try textMessage("late", from: "p"), from: "p")

        XCTAssertEqual(bridge.sent, ["late"])
    }

    /// PTY output goes only to peers that are attached AND still authorized — a
    /// connection re-using an attached peer's ID but failing the gate gets nothing.
    @MainActor
    func test_outputRecipients_areFilteredByAuthorization() {
        XCTAssertEqual(
            AgentSession.outputRecipients(attached: ["a", "b"], isAuthorized: { $0 == "a" }),
            ["a"])
    }
}
