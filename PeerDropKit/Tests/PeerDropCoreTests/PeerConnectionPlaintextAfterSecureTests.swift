// PeerDropKit/Tests/PeerDropCoreTests/PeerConnectionPlaintextAfterSecureTests.swift
//
// Issue #170: once a PeerConnection's LocalSecureChannel is established,
// `handleIncomingMessage` still forwarded every non-`.secureEnvelope` frame
// to `onMessageReceived`. TLS accepts any certificate (#167), so an on-path
// attacker could inject plaintext chat / edit / file-offer frames into a
// secured stream and have them processed as the authenticated peer's.
//
// Driven over an in-memory paired transport (no sockets).
import XCTest
import CryptoKit
@testable import PeerDropCore
@testable import PeerDropTransport
@testable import PeerDropProtocol
@testable import PeerDropSecurity

/// In-memory `LocalChannelIdentity` (no keychain).
private struct MemIdentity: LocalChannelIdentity {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }
    func deriveSharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
        try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }
}

/// Records every frame handed to the transport. Never receives (tests feed
/// frames straight into `handleIncomingMessage`).
private final class RecordingTransport: TransportProtocol {
    var isReady: Bool { true }
    var onStateChange: ((TransportState) -> Void)?
    private(set) var sent: [PeerMessage] = []
    func send(_ message: PeerMessage) async throws { sent.append(message) }
    func receive() async throws -> PeerMessage {
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        throw CancellationError()
    }
    func close() {}
}

@MainActor
final class PeerConnectionPlaintextAfterSecureTests: XCTestCase {

    private struct Pair {
        /// Ratchet INITIATOR (lex-smaller identity key): can encrypt first.
        let initiator: PeerConnection
        let initiatorTransport: RecordingTransport
        let initiatorIdentity: MemIdentity
        /// Ratchet RESPONDER: no sending chain until it receives an envelope.
        let responder: PeerConnection
        let responderTransport: RecordingTransport
        let responderIdentity: MemIdentity
        /// Frames the responder delivered to `onMessageReceived`.
        let responderInbox: Inbox
    }

    final class Inbox { var messages: [PeerMessage] = [] }

    private func makePair() -> Pair {
        var id1 = MemIdentity()
        var id2 = MemIdentity()
        if !Array(id1.publicKey.rawRepresentation)
            .lexicographicallyPrecedes(Array(id2.publicKey.rawRepresentation)) {
            swap(&id1, &id2)
        }
        let tI = RecordingTransport()
        let tR = RecordingTransport()
        let i = PeerConnection(
            peerID: "R", transport: tI,
            peerIdentity: PeerIdentity(id: "R", displayName: "Responder"),
            localIdentity: PeerIdentity(id: "I", displayName: "Initiator"),
            state: .connected)
        let r = PeerConnection(
            peerID: "I", transport: tR,
            peerIdentity: PeerIdentity(id: "I", displayName: "Initiator"),
            localIdentity: PeerIdentity(id: "R", displayName: "Responder"),
            state: .connected)
        let inbox = Inbox()
        r.onMessageReceived = { inbox.messages.append($0) }
        return Pair(initiator: i, initiatorTransport: tI, initiatorIdentity: id1,
                    responder: r, responderTransport: tR, responderIdentity: id2,
                    responderInbox: inbox)
    }

    /// Run the handshake to completion on both sides.
    private func makeSecuredPair() async throws -> Pair {
        let p = makePair()
        try await p.initiator.initiateSecureHandshake(identity: p.initiatorIdentity)
        try await p.responder.handleIncomingSecureHandshake(
            p.initiatorTransport.sent[0], identity: p.responderIdentity)
        try await p.initiator.handleIncomingSecureHandshake(
            p.responderTransport.sent[0], identity: p.initiatorIdentity)
        XCTAssertNotNil(p.initiator.secureChannel)
        XCTAssertNotNil(p.responder.secureChannel)
        return p
    }

    private func text(_ s: String) throws -> PeerMessage {
        try PeerMessage.textMessage(TextMessagePayload(text: s), senderID: "I")
    }

    // MARK: - Injected plaintext on a secured channel is dropped

    func test_secured_injectedPlaintextTextMessage_isNotDelivered() async throws {
        let p = try await makeSecuredPair()
        try await p.responder.handleIncomingMessage(try text("injected"))
        XCTAssertTrue(p.responderInbox.messages.isEmpty,
                      "plaintext .textMessage on a secured channel reached the app")
    }

    func test_secured_injectedPlaintextMessageEdit_isNotDelivered() async throws {
        let p = try await makeSecuredPair()
        let edit = try PeerMessage.messageEdit(
            MessageEditPayload(messageID: "m1", newText: "pwned"), senderID: "I")
        try await p.responder.handleIncomingMessage(edit)
        XCTAssertTrue(p.responderInbox.messages.isEmpty)
    }

    func test_secured_injectedPlaintextFileOffer_isNotDelivered() async throws {
        let p = try await makeSecuredPair()
        let offer = PeerMessage(type: .fileOffer, payload: Data("{}".utf8), senderID: "I")
        try await p.responder.handleIncomingMessage(offer)
        XCTAssertTrue(p.responderInbox.messages.isEmpty)
    }

    func test_secured_everyNonAllowlistedPlaintextType_isNotDelivered() async throws {
        let p = try await makeSecuredPair()
        for type in MessageType.allCases
        where type != .secureEnvelope && !PeerConnection.unwrappedControlTypes.contains(type) {
            try await p.responder.handleIncomingMessage(
                PeerMessage(type: type, payload: Data("{}".utf8), senderID: "I"))
        }
        XCTAssertEqual(p.responderInbox.messages.map(\.type), [],
                       "plaintext business frames reached the app on a secured channel")
    }

    // MARK: - What must keep working on a secured channel

    func test_secured_envelopeIsStillDelivered() async throws {
        let p = try await makeSecuredPair()
        try await p.initiator.sendMessage(try text("real"))
        let envelope = try XCTUnwrap(p.initiatorTransport.sent.last)
        XCTAssertEqual(envelope.type, .secureEnvelope)
        try await p.responder.handleIncomingMessage(envelope)
        XCTAssertEqual(p.responderInbox.messages.map(\.type), [.textMessage])
        let payload = try p.responderInbox.messages[0].decodePayload(TextMessagePayload.self)
        XCTAssertEqual(payload.text, "real")
    }

    func test_secured_allowlistedControlFrames_areStillDelivered() async throws {
        let p = try await makeSecuredPair()
        try await p.responder.handleIncomingMessage(.ping(senderID: "I"))
        try await p.responder.handleIncomingMessage(.pong(senderID: "I"))
        try await p.responder.handleIncomingMessage(.disconnect(senderID: "I"))
        XCTAssertEqual(p.responderInbox.messages.map(\.type), [.ping, .pong, .disconnect])
    }

    func test_secured_duplicateHandshake_isStillHandledInternally() async throws {
        let p = try await makeSecuredPair()
        let fingerprint = p.responder.secureChannel?.peerFingerprint
        try await p.responder.handleIncomingMessage(p.initiatorTransport.sent[0])
        XCTAssertEqual(p.responder.secureChannelState, .secured)
        XCTAssertEqual(p.responder.secureChannel?.peerFingerprint, fingerprint)
        XCTAssertTrue(p.responderInbox.messages.isEmpty)
    }

    // MARK: - Before the channel is established: unchanged

    func test_unsecured_plaintextBusinessFrames_areDelivered() async throws {
        let p = makePair()   // never negotiated (legacy / v5.0.x peer)
        try await p.responder.handleIncomingMessage(try text("legacy"))
        let edit = try PeerMessage.messageEdit(MessageEditPayload(messageID: "m", newText: "x"), senderID: "I")
        try await p.responder.handleIncomingMessage(edit)
        XCTAssertEqual(p.responderInbox.messages.map(\.type), [.textMessage, .messageEdit])
    }

    func test_handshakeInProgress_plaintextBusinessFrames_areDelivered() async throws {
        let p = makePair()
        try await p.responder.initiateSecureHandshake(identity: p.responderIdentity)
        XCTAssertEqual(p.responder.secureChannelState, .handshakeInProgress)
        try await p.responder.handleIncomingMessage(try text("early"))
        XCTAssertEqual(p.responderInbox.messages.map(\.type), [.textMessage])
    }

    // MARK: - Send and receive allowlists are the same set

    func test_unwrappedControlTypes_isExactlyTheHonestUnwrappedSet() {
        XCTAssertEqual(PeerConnection.unwrappedControlTypes,
                       [.secureHandshake, .ping, .pong, .disconnect])
    }

    /// Every type a secured sender puts on the wire unwrapped must be one the
    /// secured receiver accepts, and vice versa — no type is accepted
    /// unwrapped that the sender would have wrapped.
    func test_sendSideUnwrappedTypes_equalReceiveSideAllowlist() async throws {
        let p = try await makeSecuredPair()
        var sentUnwrapped = Set<MessageType>()
        for type in MessageType.allCases where type != .secureEnvelope {
            let before = p.initiatorTransport.sent.count
            try await p.initiator.sendMessage(PeerMessage(type: type, payload: nil, senderID: "I"))
            let wire = p.initiatorTransport.sent[before]
            if wire.type != .secureEnvelope { sentUnwrapped.insert(wire.type) }
        }
        // `disconnect()` writes straight to the transport.
        await p.initiator.disconnect()
        if let last = p.initiatorTransport.sent.last, last.type != .secureEnvelope {
            sentUnwrapped.insert(last.type)
        }
        // `.secureHandshake` is sent by the handshake itself (bundle / reply).
        sentUnwrapped.formUnion(p.initiatorTransport.sent.prefix(1).map(\.type))

        var acceptedUnwrapped = Set<MessageType>()
        let q = try await makeSecuredPair()
        for type in MessageType.allCases where type != .secureEnvelope {
            let before = q.responderInbox.messages.count
            if type == .secureHandshake {
                // Handled internally, never forwarded; accepted = not dropped
                // (duplicate is a logged no-op on the live channel).
                try await q.responder.handleIncomingMessage(q.initiatorTransport.sent[0])
                if q.responder.secureChannelState == .secured { acceptedUnwrapped.insert(type) }
                continue
            }
            try await q.responder.handleIncomingMessage(
                PeerMessage(type: type, payload: Data("{}".utf8), senderID: "I"))
            if q.responderInbox.messages.count > before { acceptedUnwrapped.insert(type) }
        }
        XCTAssertEqual(sentUnwrapped, PeerConnection.unwrappedControlTypes)
        XCTAssertEqual(acceptedUnwrapped, PeerConnection.unwrappedControlTypes)
    }

    // MARK: - Honest sender never emits plaintext business frames after its bundle

    /// Once we have sent our handshake bundle the peer will be `.secured` as
    /// soon as it reads it, so any plaintext business frame we send afterwards
    /// would be dropped. Such sends wait for the channel, then go encrypted.
    func test_businessSendDuringHandshake_isHeldThenSentEncrypted() async throws {
        let p = makePair()
        try await p.initiator.initiateSecureHandshake(identity: p.initiatorIdentity)
        let send = Task { try await p.initiator.sendMessage(try self.text("early")) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(p.initiatorTransport.sent.map(\.type), [.secureHandshake],
                       "business frame went out plaintext after our handshake bundle")

        try await p.responder.handleIncomingSecureHandshake(
            p.initiatorTransport.sent[0], identity: p.responderIdentity)
        try await p.initiator.handleIncomingSecureHandshake(
            p.responderTransport.sent[0], identity: p.initiatorIdentity)
        try await send.value
        XCTAssertEqual(p.initiatorTransport.sent.map(\.type), [.secureHandshake, .secureEnvelope])

        // ...and the secured peer accepts it.
        try await p.responder.handleIncomingMessage(p.initiatorTransport.sent[1])
        XCTAssertEqual(p.responderInbox.messages.map(\.type), [.textMessage])
    }

    /// The ratchet responder has no sending chain until the initiator's first
    /// envelope arrives; a business send in that gap waits for it instead of
    /// failing with `noSendChain`.
    func test_responderBusinessSend_waitsForFirstInboundEnvelope() async throws {
        let p = makePair()
        try await p.initiator.initiateSecureHandshake(identity: p.initiatorIdentity)
        try await p.responder.handleIncomingSecureHandshake(
            p.initiatorTransport.sent[0], identity: p.responderIdentity)
        try await p.initiator.handleIncomingSecureHandshake(
            p.responderTransport.sent[0], identity: p.initiatorIdentity)
        XCTAssertEqual(p.responder.secureChannel?.isInitiator, false)

        let send = Task { try await p.responder.sendMessage(try self.text("reply")) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(p.responderTransport.sent.map(\.type), [.secureHandshake])

        // The initiator's bootstrap envelope gives the responder a send chain.
        try await p.initiator.sendMessage(try text("bootstrap"))
        try await p.responder.handleIncomingMessage(p.initiatorTransport.sent.last!)
        try await send.value
        XCTAssertEqual(p.responderTransport.sent.map(\.type), [.secureHandshake, .secureEnvelope])
    }

    func test_heldSend_isReleasedPlaintextOnHandshakeFallback() async throws {
        let p = makePair()
        p.initiator.handshakeFallbackNanoseconds = 100_000_000
        try await p.initiator.initiateSecureHandshake(identity: p.initiatorIdentity)
        try await p.initiator.sendMessage(try text("after fallback"))
        XCTAssertEqual(p.initiator.secureChannelState, .fallbackPlaintext)
        XCTAssertEqual(p.initiatorTransport.sent.map(\.type), [.secureHandshake, .textMessage])
    }

    func test_heldSend_failsWhenConnectionDrops() async throws {
        let p = makePair()
        try await p.initiator.initiateSecureHandshake(identity: p.initiatorIdentity)
        let send = Task { try await p.initiator.sendMessage(try self.text("x")) }
        try await Task.sleep(nanoseconds: 50_000_000)
        p.initiator.updateState(.disconnected)
        do {
            try await send.value
            XCTFail("held send should fail once the connection is gone")
        } catch {}
        XCTAssertEqual(p.initiatorTransport.sent.map(\.type), [.secureHandshake])
    }

    func test_controlFramesAreNotHeldDuringHandshake() async throws {
        let p = makePair()
        try await p.initiator.initiateSecureHandshake(identity: p.initiatorIdentity)
        try await p.initiator.sendMessage(.ping(senderID: "I"))
        XCTAssertEqual(p.initiatorTransport.sent.map(\.type), [.secureHandshake, .ping])
    }
}

