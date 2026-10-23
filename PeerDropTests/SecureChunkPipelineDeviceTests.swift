// Same secure-chunk pipeline as SecureChunkPipelineBaselineTests, run from the app test bundle so it can target a real device:
//   xcodebuild test -scheme PeerDrop -destination "id=<device>" -only-testing:PeerDropTests/SecureChunkPipelineDeviceTests
import XCTest
import CryptoKit
import PeerDropPlatform
import PeerDropProtocol
import PeerDropSecurity
@testable import PeerDrop
@testable import PeerDropTransport
@testable import PeerDropCore

@MainActor
final class SecureChunkPipelineDeviceTests: XCTestCase {
    /// Secure-channel chunk path: what each 64 KB chunk costs on the main actor in
    /// PeerConnection (JSON+base64 encode/decode, ratchet encrypt/decrypt). The
    /// ratchet is stateful, so any offload has to keep it serial and in order.
    func testSecureChunkPipeline() async throws {
        struct Ident: LocalChannelIdentity {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }
            func deriveSharedSecret(with peer: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
                try privateKey.sharedSecretFromKeyAgreement(with: peer)
            }
        }
        final class Loop: TransportProtocol {
            var isReady = true
            var onStateChange: ((TransportState) -> Void)?
            var sent: [PeerMessage] = []
            func send(_ message: PeerMessage) async throws { sent.append(message) }
            func receive() async throws -> PeerMessage { throw CancellationError() }
            func close() {}
        }
        var i1 = Ident(), i2 = Ident()
        if !Array(i1.publicKey.rawRepresentation).lexicographicallyPrecedes(Array(i2.publicKey.rawRepresentation)) { swap(&i1, &i2) }
        let (ta, tb) = (Loop(), Loop())
        let la = PeerIdentity(id: "A", displayName: "A"), lb = PeerIdentity(id: "B", displayName: "B")
        let a = PeerConnection(peerID: "b", transport: ta, peerIdentity: lb, localIdentity: la, state: .connected)
        let b = PeerConnection(peerID: "a", transport: tb, peerIdentity: la, localIdentity: lb, state: .connected)
        try await a.initiateSecureHandshake(identity: i1)
        try await b.handleIncomingSecureHandshake(ta.sent[0], identity: i2)
        try await a.handleIncomingSecureHandshake(tb.sent[0], identity: i1)
        PerfSignpost.reset()

        let chunk = Data(repeating: 0xAB, count: Data.defaultChunkSize)
        var received = 0
        b.onMessageReceived = { _ in received += 1 }
        let n = 256                                        // 16 MB
        for _ in 0..<n {
            try await a.sendMessage(PeerMessage.fileChunk(chunk, senderID: "A"))
            try await b.handleIncomingMessage(ta.sent.removeLast())
        }
        XCTAssertEqual(received, n)
        print("[perf-baseline-device] secure chunk pipeline 16MB\n" + PerfSignpost.report())
    }
}
