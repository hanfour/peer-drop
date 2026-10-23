import XCTest
import CryptoKit
import PeerDropProtocol
import PeerDropSecurity
@testable import PeerDropTransport
@testable import PeerDropCore

/// Receive-side decrypt/decode runs off the main actor. A result that finishes
/// after the connection was replaced or closed belongs to a dead transport and
/// must not reach `onMessageReceived`.
@MainActor
final class SecureReceiveGenerationTests: XCTestCase {
    private struct Ident: LocalChannelIdentity {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }
        func deriveSharedSecret(with peer: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
            try privateKey.sharedSecretFromKeyAgreement(with: peer)
        }
    }
    private final class Loop: TransportProtocol {
        var isReady = true
        var onStateChange: ((TransportState) -> Void)?
        var sent: [PeerMessage] = []
        func send(_ message: PeerMessage) async throws { sent.append(message) }
        func receive() async throws -> PeerMessage { throw CancellationError() }
        func close() {}
    }

    /// Two secured connections; returns the receiver and one encrypted envelope
    /// from the sender.
    private func makeSecuredPairAndEnvelope() async throws -> (receiver: PeerConnection, envelope: PeerMessage) {
        var i1 = Ident(), i2 = Ident()
        if !Array(i1.publicKey.rawRepresentation).lexicographicallyPrecedes(Array(i2.publicKey.rawRepresentation)) { swap(&i1, &i2) }
        let (ta, tb) = (Loop(), Loop())
        let la = PeerIdentity(id: "A", displayName: "A"), lb = PeerIdentity(id: "B", displayName: "B")
        let a = PeerConnection(peerID: "b", transport: ta, peerIdentity: lb, localIdentity: la, state: .connected)
        let b = PeerConnection(peerID: "a", transport: tb, peerIdentity: la, localIdentity: lb, state: .connected)
        try await a.initiateSecureHandshake(identity: i1)
        try await b.handleIncomingSecureHandshake(ta.sent[0], identity: i2)
        try await a.handleIncomingSecureHandshake(tb.sent[0], identity: i1)
        ta.sent.removeAll()
        try await a.sendMessage(PeerMessage.fileChunk(Data(repeating: 1, count: 1_000), senderID: "A"))
        XCTAssertEqual(ta.sent.count, 1)
        return (b, ta.sent[0])
    }

    /// Control: the same flow without replacing the connection delivers, so the
    /// drop test below can't pass just because delivery never happens.
    func testDeliversWhenConnectionUnchanged() async throws {
        let (b, envelope) = try await makeSecuredPairAndEnvelope()
        var received = 0
        b.onMessageReceived = { _ in received += 1 }
        let task = Task { try await b.handleIncomingMessage(envelope) }
        await Task.yield()                  // task runs until its off-main decrypt suspends it
        try await task.value
        XCTAssertEqual(received, 1)
    }

    func testDropsResultWhenConnectionReplacedDuringDecrypt() async throws {
        let (b, envelope) = try await makeSecuredPairAndEnvelope()
        var received = 0
        b.onMessageReceived = { _ in received += 1 }
        let task = Task { try await b.handleIncomingMessage(envelope) }
        await Task.yield()                  // task is now suspended in the off-main decrypt
        // Still on the main actor, so the task cannot resume before this runs:
        // disconnect(sendMessage: false) bumps connectionGeneration with no await.
        await b.disconnect(sendMessage: false)
        try await task.value
        XCTAssertEqual(received, 0)
    }
}
