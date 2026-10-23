import XCTest
import CryptoKit
import PeerDropProtocol
import PeerDropSecurity
@testable import PeerDropTransport
@testable import PeerDropCore

/// H7 end to end over a real secure channel: the receiver must get the file
/// bytes, not just the metadata.
@MainActor
final class MediaMessageWireTests: XCTestCase {
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

    func testMediaBytesArriveThroughSecureChannel() async throws {
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

        let bytes = Data((0..<2_000_000).map { UInt8($0 % 251) })
        let payload = MediaMessagePayload(
            mediaType: .image, fileName: "p.jpg", fileSize: Int64(bytes.count),
            mimeType: "image/jpeg", duration: nil, thumbnailData: Data([1, 2, 3]), fileData: bytes)
        try await a.sendMessage(PeerMessage.mediaMessage(payload, senderID: "A"))

        var received: MediaMessagePayload?
        b.onMessageReceived = { received = try? $0.decodePayload(MediaMessagePayload.self) }
        for m in ta.sent { try await b.handleIncomingMessage(m) }

        XCTAssertEqual(received?.validatedFileData, bytes)
        XCTAssertEqual(received?.thumbnailData, Data([1, 2, 3]))
    }
}
