import XCTest
import CryptoKit
@testable import PeerDropCore
@testable import PeerDropTransport
@testable import PeerDropProtocol
@testable import PeerDropSecurity

private struct OriginMemIdentity: LocalChannelIdentity {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }
    func deriveSharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
        try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }
}

private final class OriginRecordingTransport: TransportProtocol {
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
final class PeerConnectionMessageOriginTests: XCTestCase {
    private struct Pair {
        let us: PeerConnection        // receiver (ratchet responder)
        let peer: PeerConnection      // sender (ratchet initiator)
        let peerT: OriginRecordingTransport
    }

    private func securedPair(peerVersion: Int) async throws -> Pair {
        var id1 = OriginMemIdentity()
        var id2 = OriginMemIdentity()
        if !Array(id1.publicKey.rawRepresentation)
            .lexicographicallyPrecedes(Array(id2.publicKey.rawRepresentation)) { swap(&id1, &id2) }
        let usT = OriginRecordingTransport()
        let peerT = OriginRecordingTransport()
        let us = PeerConnection(
            peerID: "P", transport: usT,
            peerIdentity: PeerIdentity(id: "P", displayName: "Peer", secureChannelVersion: peerVersion),
            localIdentity: PeerIdentity(id: "U", displayName: "Us"), state: .connected)
        let peer = PeerConnection(
            peerID: "U", transport: peerT,
            peerIdentity: PeerIdentity(id: "U", displayName: "Us"),
            localIdentity: PeerIdentity(id: "P", displayName: "Peer"), state: .connected)
        try await peer.initiateSecureHandshake(identity: id1)
        try await us.handleIncomingSecureHandshake(peerT.sent[0], identity: id2)
        try await peer.handleIncomingSecureHandshake(usT.sent[0], identity: id1)
        XCTAssertNotNil(us.secureChannel)
        return Pair(us: us, peer: peer, peerT: peerT)
    }

    private func notes() throws -> PeerMessage {
        try PeerMessage.notesExchange(NotesExchangePayload(phase: "intent", nonce: Data(count: 32)), senderID: "P")
    }

    func testNotesExchangeIsNotAnUnwrappedControlType() {
        XCTAssertFalse(PeerConnection.unwrappedControlTypes.contains(.notesExchange))
    }

    func testEnvelopeOriginForSealedNotesExchange() async throws {
        let p = try await securedPair(peerVersion: 2)
        var got: [(PeerMessage, PeerConnection.MessageOrigin)] = []
        p.us.onMessageReceivedWithOrigin = { got.append(($0, $1)) }
        try await p.peer.sendMessage(try notes())
        let frame = try XCTUnwrap(p.peerT.sent.last)
        XCTAssertEqual(frame.type, .secureEnvelope)
        try await p.us.handleIncomingMessage(frame)
        XCTAssertEqual(got.map(\.0.type), [.notesExchange])
        XCTAssertEqual(got.map(\.1), [.envelope])
    }

    func testPlaintextOriginInLegacyWindow() async throws {
        let p = try await securedPair(peerVersion: 1)
        var got: [(PeerMessage, PeerConnection.MessageOrigin)] = []
        p.us.onMessageReceivedWithOrigin = { got.append(($0, $1)) }
        try await p.us.handleIncomingMessage(try notes())
        XCTAssertEqual(got.map(\.1), [.plaintext])
    }

    func testLegacySingleArgClosureStillCalled() async throws {
        let p = try await securedPair(peerVersion: 2)
        var got: [PeerMessage] = []
        p.us.onMessageReceived = { got.append($0) }
        try await p.peer.sendMessage(try notes())
        try await p.us.handleIncomingMessage(try XCTUnwrap(p.peerT.sent.last))
        XCTAssertEqual(got.map(\.type), [.notesExchange])
    }
}
