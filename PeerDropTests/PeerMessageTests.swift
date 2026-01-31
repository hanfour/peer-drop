import XCTest
@testable import PeerDrop

final class PeerMessageTests: XCTestCase {

    // MARK: - Round-trip encoding

    func testSimpleMessageRoundTrip() throws {
        let message = PeerMessage(type: .connectionRequest, senderID: "peer-1")
        let data = try message.encoded()
        let decoded = try PeerMessage.decoded(from: data)

        XCTAssertEqual(decoded.type, .connectionRequest)
        XCTAssertEqual(decoded.senderID, "peer-1")
        XCTAssertEqual(decoded.version, .v1)
        XCTAssertNil(decoded.payload)
    }

    func testMessageWithPayloadRoundTrip() throws {
        let payload = "test data".data(using: .utf8)!
        let message = PeerMessage(type: .fileChunk, payload: payload, senderID: "peer-2")
        let data = try message.encoded()
        let decoded = try PeerMessage.decoded(from: data)

        XCTAssertEqual(decoded.type, .fileChunk)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.senderID, "peer-2")
    }

    func testHelloMessageRoundTrip() throws {
        let identity = PeerIdentity(displayName: "Test Device")
        let message = try PeerMessage.hello(identity: identity)
        let data = try message.encoded()
        let decoded = try PeerMessage.decoded(from: data)

        XCTAssertEqual(decoded.type, .hello)
        let decodedIdentity = try decoded.decodePayload(PeerIdentity.self)
        XCTAssertEqual(decodedIdentity.displayName, "Test Device")
    }

    func testFileOfferRoundTrip() throws {
        let metadata = TransferMetadata(
            fileName: "test.txt",
            fileSize: 1024,
            mimeType: "text/plain",
            sha256Hash: "abc123"
        )
        let message = try PeerMessage.fileOffer(metadata: metadata, senderID: "sender")
        let data = try message.encoded()
        let decoded = try PeerMessage.decoded(from: data)

        XCTAssertEqual(decoded.type, .fileOffer)
        let decodedMeta = try decoded.decodePayload(TransferMetadata.self)
        XCTAssertEqual(decodedMeta.fileName, "test.txt")
        XCTAssertEqual(decodedMeta.fileSize, 1024)
        XCTAssertEqual(decodedMeta.sha256Hash, "abc123")
    }

    // MARK: - All message types

    func testAllMessageTypesEncodable() throws {
        let types: [MessageType] = [
            .hello, .connectionRequest, .connectionAccept, .connectionReject,
            .fileOffer, .fileAccept, .fileReject, .fileChunk, .fileComplete,
            .sdpOffer, .sdpAnswer, .iceCandidate,
            .callRequest, .callAccept, .callReject, .callEnd,
            .disconnect
        ]

        for type in types {
            let message = PeerMessage(type: type, senderID: "test")
            let data = try message.encoded()
            let decoded = try PeerMessage.decoded(from: data)
            XCTAssertEqual(decoded.type, type, "Round-trip failed for \(type)")
        }
    }

    // MARK: - Error cases

    func testDecodePayloadMissingThrows() {
        let message = PeerMessage(type: .hello, senderID: "test")
        XCTAssertThrowsError(try message.decodePayload(PeerIdentity.self))
    }
}
