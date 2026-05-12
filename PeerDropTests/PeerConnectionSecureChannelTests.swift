import XCTest
import CryptoKit
@testable import PeerDrop

/// Integration tests for the audit-#13 Phase 2 wiring: handshake state
/// machine + automatic encrypt-on-send + decrypt-on-receive in
/// `PeerConnection`.
///
/// Driven through a paired `MockTransport` (no real socket); two
/// connections share opposite ends of a queue so messages sent by one
/// side arrive on the other and we can exercise the full bidirectional
/// flow synchronously.
@MainActor
final class PeerConnectionSecureChannelTests: XCTestCase {

    // MARK: - Test doubles

    /// In-memory `LocalChannelIdentity` backed by a fresh keypair.
    struct TestIdentity: LocalChannelIdentity {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }
        init() { self.privateKey = Curve25519.KeyAgreement.PrivateKey() }
        func deriveSharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
            try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        }
    }

    /// A paired mock transport. Two halves; each `send` on one half
    /// enqueues for the other half's `receive`. Lets one PeerConnection
    /// exchange messages with another in the same test, no networking.
    final class MockTransport: TransportProtocol {
        var isReady: Bool = true
        var onStateChange: ((TransportState) -> Void)?

        /// Inbound queue with a per-message continuation so `receive()`
        /// can yield correctly even when called before `send` arrives.
        private var inbox: [PeerMessage] = []
        private var inboxWaiters: [CheckedContinuation<PeerMessage, Error>] = []
        private weak var partner: MockTransport?
        private(set) var sentMessages: [PeerMessage] = []

        static func makePair() -> (MockTransport, MockTransport) {
            let a = MockTransport()
            let b = MockTransport()
            a.partner = b
            b.partner = a
            return (a, b)
        }

        func send(_ message: PeerMessage) async throws {
            sentMessages.append(message)
            partner?.deliver(message)
        }

        private func deliver(_ message: PeerMessage) {
            if let waiter = inboxWaiters.first {
                inboxWaiters.removeFirst()
                waiter.resume(returning: message)
            } else {
                inbox.append(message)
            }
        }

        func receive() async throws -> PeerMessage {
            if !inbox.isEmpty { return inbox.removeFirst() }
            return try await withCheckedThrowingContinuation { cont in
                inboxWaiters.append(cont)
            }
        }

        func close() {}
    }

    // MARK: - Helpers

    private func makePair() -> (a: PeerConnection, aTransport: MockTransport, aIdentity: TestIdentity,
                                b: PeerConnection, bTransport: MockTransport, bIdentity: TestIdentity) {
        // Generate two identities; assign so `aIdentity` is always the
        // ratchet-INITIATOR (lex-smaller public key). The Double Ratchet
        // requires the initiator to send the first encrypted message —
        // tests that assume "A encrypts, B receives" only work if A is
        // the initiator side. Re-rolling on lex match is loop-free in
        // practice because Curve25519 keys are uniformly distributed.
        var id1 = TestIdentity()
        var id2 = TestIdentity()
        let id1Bytes = Array(id1.publicKey.rawRepresentation)
        let id2Bytes = Array(id2.publicKey.rawRepresentation)
        if !id1Bytes.lexicographicallyPrecedes(id2Bytes) {
            swap(&id1, &id2)
        }
        let aIdentity = id1  // lex-smaller → ratchet initiator
        let bIdentity = id2

        let (aTransport, bTransport) = MockTransport.makePair()
        let aLocal = PeerIdentity(id: "A", displayName: "Alice")
        let bLocal = PeerIdentity(id: "B", displayName: "Bob")

        let a = PeerConnection(
            peerID: "B-as-peer-of-A",
            transport: aTransport,
            peerIdentity: bLocal,
            localIdentity: aLocal,
            state: .connected
        )
        let b = PeerConnection(
            peerID: "A-as-peer-of-B",
            transport: bTransport,
            peerIdentity: aLocal,
            localIdentity: bLocal,
            state: .connected
        )

        return (a, aTransport, aIdentity, b, bTransport, bIdentity)
    }

    // MARK: - Initial state

    func test_freshConnection_secureChannelIsDisabled() {
        let (a, _, _, _, _, _) = makePair()
        XCTAssertNil(a.secureChannel)
        XCTAssertEqual(a.secureChannelState, .disabled)
    }

    // MARK: - Handshake — active initiator side

    func test_initiateSecureHandshake_sendsBundleAndTransitionsState() async throws {
        let (a, aTransport, aIdentity, _, _, _) = makePair()
        try await a.initiateSecureHandshake(identity: aIdentity)

        XCTAssertEqual(a.secureChannelState, .handshakeInProgress)
        XCTAssertNil(a.secureChannel, "channel only set after peer's bundle arrives")
        XCTAssertEqual(aTransport.sentMessages.count, 1)
        XCTAssertEqual(aTransport.sentMessages.first?.type, .secureHandshake)
    }

    func test_initiateSecureHandshake_idempotent() async throws {
        let (a, aTransport, aIdentity, _, _, _) = makePair()
        try await a.initiateSecureHandshake(identity: aIdentity)
        try await a.initiateSecureHandshake(identity: aIdentity)
        XCTAssertEqual(aTransport.sentMessages.count, 1, "second call is a no-op")
    }

    // MARK: - Full bidirectional handshake

    func test_fullHandshake_bothSidesEstablishChannel() async throws {
        let (a, aTransport, aIdentity, b, bTransport, bIdentity) = makePair()

        // A initiates — sends its bundle.
        try await a.initiateSecureHandshake(identity: aIdentity)
        let aToB = aTransport.sentMessages[0]
        XCTAssertEqual(aToB.type, .secureHandshake)

        // B receives — sends its own bundle in response and establishes.
        try await b.handleIncomingSecureHandshake(aToB, identity: bIdentity)
        XCTAssertEqual(b.secureChannelState, .secured)
        XCTAssertNotNil(b.secureChannel)
        XCTAssertEqual(bTransport.sentMessages.count, 1, "B sent its bundle in reply")

        // A receives B's bundle — establishes its side. Now both channels exist.
        let bToA = bTransport.sentMessages[0]
        try await a.handleIncomingSecureHandshake(bToA, identity: aIdentity)
        XCTAssertEqual(a.secureChannelState, .secured)
        XCTAssertNotNil(a.secureChannel)
    }

    // MARK: - Encrypted message round-trip

    func test_sendMessage_afterHandshake_wrapsInSecureEnvelope() async throws {
        let (a, aTransport, aIdentity, b, bTransport, bIdentity) = makePair()
        try await a.initiateSecureHandshake(identity: aIdentity)
        try await b.handleIncomingSecureHandshake(aTransport.sentMessages[0], identity: bIdentity)
        try await a.handleIncomingSecureHandshake(bTransport.sentMessages[0], identity: aIdentity)

        // Now send a textMessage from A → B. It should go out as a
        // .secureEnvelope, NOT a raw .textMessage.
        let payload = TextMessagePayload(text: "hello")
        let plaintextMsg = try PeerMessage.textMessage(payload, senderID: "A")
        try await a.sendMessage(plaintextMsg)

        let onWire = aTransport.sentMessages.last
        XCTAssertEqual(onWire?.type, .secureEnvelope,
                       "encrypted send must wrap as .secureEnvelope on the wire")
        XCTAssertNotNil(onWire?.payload)
        // Crucial: the wire payload must NOT contain the plaintext.
        if let body = onWire?.payload, let plain = "hello".data(using: .utf8) {
            XCTAssertFalse(body.range(of: plain) != nil,
                           "plaintext leaked into the wire payload")
        }
    }

    func test_bypassTypes_alwaysGoPlaintext_evenAfterHandshake() async throws {
        let (a, aTransport, aIdentity, b, bTransport, bIdentity) = makePair()
        try await a.initiateSecureHandshake(identity: aIdentity)
        try await b.handleIncomingSecureHandshake(aTransport.sentMessages[0], identity: bIdentity)
        try await a.handleIncomingSecureHandshake(bTransport.sentMessages[0], identity: aIdentity)

        // Ping is in the bypass set — sent as-is, not encrypted.
        try await a.sendMessage(PeerMessage.ping(senderID: "A"))
        let onWire = aTransport.sentMessages.last
        XCTAssertEqual(onWire?.type, .ping, "ping bypasses encryption to keep keepalive cheap")
    }

    // MARK: - Receive loop unwrap

    func test_handleIncomingMessage_unwrapsSecureEnvelope() async throws {
        let (a, aTransport, aIdentity, b, bTransport, bIdentity) = makePair()
        try await a.initiateSecureHandshake(identity: aIdentity)
        try await b.handleIncomingSecureHandshake(aTransport.sentMessages[0], identity: bIdentity)
        try await a.handleIncomingSecureHandshake(bTransport.sentMessages[0], identity: aIdentity)

        // The leftover handshake bundle is still in b's transport inbox
        // (we manually drove the handshake; receive loop never drained
        // it). Use an expectation-driven wait so the test doesn't race
        // against the receive Task — the receive loop will see the
        // already-handled bundle and the new envelope in order.
        let envelopeReceived = expectation(description: "envelope unwrapped to textMessage")
        var receivedMessages: [PeerMessage] = []
        b.onMessageReceived = { msg in
            receivedMessages.append(msg)
            if msg.type == .textMessage { envelopeReceived.fulfill() }
        }

        let payload = TextMessagePayload(text: "secret")
        let plaintextMsg = try PeerMessage.textMessage(payload, senderID: "A")
        try await a.sendMessage(plaintextMsg)

        b.startReceiving()
        await fulfillment(of: [envelopeReceived], timeout: 2.0)

        let firstTextMessage = receivedMessages.first(where: { $0.type == .textMessage })
        XCTAssertNotNil(firstTextMessage)
        let decodedPayload = try firstTextMessage?.decodePayload(TextMessagePayload.self)
        XCTAssertEqual(decodedPayload?.text, "secret")
    }

    // MARK: - v5.1 fallback + pinning surface

    func test_startSecureChannelNegotiation_peerDoesNotSupport_staysDisabled() async {
        let (a, aTransport, aIdentity, _, _, _) = makePair()
        await a.startSecureChannelNegotiation(peerSupportsSecureChannel: false, identity: aIdentity)
        XCTAssertEqual(a.secureChannelState, .disabled, "no handshake should fire against a v5.0.x peer")
        XCTAssertTrue(aTransport.sentMessages.isEmpty, "must not leak a .secureHandshake to peers who can't decode it")
    }

    func test_startSecureChannelNegotiation_peerSupports_initiatesHandshake() async {
        let (a, aTransport, aIdentity, _, _, _) = makePair()
        await a.startSecureChannelNegotiation(peerSupportsSecureChannel: true, identity: aIdentity)
        XCTAssertEqual(a.secureChannelState, .handshakeInProgress)
        XCTAssertEqual(aTransport.sentMessages.first?.type, .secureHandshake)
    }

    func test_onSecureChannelEstablished_firesAfterHandshake() async throws {
        let (a, aTransport, aIdentity, b, bTransport, bIdentity) = makePair()
        let expect = expectation(description: "callback fires with peer fingerprint")
        var observedFingerprint: String?
        a.onSecureChannelEstablished = { fp in
            observedFingerprint = fp
            expect.fulfill()
        }
        try await a.initiateSecureHandshake(identity: aIdentity)
        try await b.handleIncomingSecureHandshake(aTransport.sentMessages[0], identity: bIdentity)
        try await a.handleIncomingSecureHandshake(bTransport.sentMessages[0], identity: aIdentity)
        await fulfillment(of: [expect], timeout: 1.0)
        XCTAssertNotNil(observedFingerprint)
        XCTAssertEqual(observedFingerprint, a.secureChannel?.peerFingerprint)
    }

    func test_setPinningVerdict_updatesPublishedState() {
        let (a, _, _, _, _, _) = makePair()
        XCTAssertEqual(a.pinningVerdict, .notChecked)
        a.setPinningVerdict(.firstTrust)
        XCTAssertEqual(a.pinningVerdict, .firstTrust)
        a.setPinningVerdict(.mismatch(stored: "AAAA", received: "BBBB"))
        XCTAssertEqual(a.pinningVerdict, .mismatch(stored: "AAAA", received: "BBBB"))
    }

    func test_duplicateHandshake_preservesExistingChannel() async throws {
        let (a, aTransport, aIdentity, b, bTransport, bIdentity) = makePair()
        try await a.initiateSecureHandshake(identity: aIdentity)
        try await b.handleIncomingSecureHandshake(aTransport.sentMessages[0], identity: bIdentity)
        try await a.handleIncomingSecureHandshake(bTransport.sentMessages[0], identity: aIdentity)

        // Capture the established channel's identity before the replay.
        let originalPeerFingerprint = b.secureChannel?.peerFingerprint

        // Replay the same handshake bundle. Without the guard, this would
        // generate a new ratchet key + replace b.secureChannel, breaking
        // every in-flight encrypted message.
        try await b.handleIncomingSecureHandshake(aTransport.sentMessages[0], identity: bIdentity)

        XCTAssertEqual(b.secureChannelState, .secured, "still secured")
        XCTAssertEqual(b.secureChannel?.peerFingerprint, originalPeerFingerprint,
                       "channel identity unchanged — replay was a no-op")
    }
}
