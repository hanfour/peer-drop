import XCTest
import CryptoKit
import PeerDropProtocol
import PeerDropSecurity
@testable import PeerDropTransport
@testable import PeerDropCore

/// The secure send path encrypts off the main actor; the ratchet counter and
/// wire order must still equal call order, or the receiver fails to decrypt.
@MainActor
final class SecureSendOrderingTests: XCTestCase {
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

    func testConcurrentSendsKeepCallOrderOnWire() async throws {
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

        let n = 100
        var tasks: [Task<Void, Error>] = []
        for k in 0..<n {
            let payload = Data([UInt8(k)]) + Data(repeating: 0x5A, count: 20_000)
            tasks.append(Task { try await a.sendMessage(PeerMessage.fileChunk(payload, senderID: "A")) })
            await Task.yield()
        }
        for t in tasks { try await t.value }
        XCTAssertEqual(ta.sent.count, n)

        var got: [UInt8] = []
        b.onMessageReceived = { got.append($0.payload?.first ?? 255) }
        for m in ta.sent { try await b.handleIncomingMessage(m) }
        XCTAssertEqual(got, (0..<n).map { UInt8($0) })
    }
}
