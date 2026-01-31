import XCTest
@testable import PeerDrop

final class MessageFramerTests: XCTestCase {

    func testFramerDefinitionLabel() {
        XCTAssertEqual(PeerDropFramer.label, "PeerDrop")
    }

    func testMessageMetadataRoundTrip() {
        let length: UInt32 = 1024
        let message = NWProtocolFramer.Message(peerDropMessageLength: length)
        XCTAssertEqual(message.peerDropMessageLength, length)
    }

    func testMessageMetadataZeroLength() {
        let message = NWProtocolFramer.Message(peerDropMessageLength: 0)
        XCTAssertEqual(message.peerDropMessageLength, 0)
    }

    func testMessageMetadataMaxLength() {
        let message = NWProtocolFramer.Message(peerDropMessageLength: UInt32.max)
        XCTAssertEqual(message.peerDropMessageLength, UInt32.max)
    }
}

import Network
