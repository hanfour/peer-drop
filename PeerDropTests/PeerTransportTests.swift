import XCTest
@testable import PeerDrop

final class PeerTransportTests: XCTestCase {

    // Uses the shared MockTransport from Mocks/MockTransport.swift

    func testTransportProtocolConformance() {
        let transport = MockTransport()
        XCTAssertTrue(transport.isReady)
    }

    func testMockTransportSend() async throws {
        let transport = MockTransport()
        let message = PeerMessage.ping(senderID: "test")
        try await transport.send(message)
        XCTAssertEqual(transport.sentMessages.count, 1)
        XCTAssertEqual(transport.sentMessages[0].type, .ping)
    }

    func testMockTransportClose() {
        let transport = MockTransport()
        var stateChanged = false
        transport.onStateChange = { state in
            if case .cancelled = state { stateChanged = true }
        }
        transport.close()
        XCTAssertTrue(transport.isClosed)
        XCTAssertTrue(stateChanged)
    }

    func testTransportStateEnum() {
        let connecting = TransportState.connecting
        let ready = TransportState.ready
        let cancelled = TransportState.cancelled
        let failed = TransportState.failed(NSError(domain: "test", code: 1))

        switch connecting {
        case .connecting: break
        default: XCTFail("Expected connecting")
        }
        switch ready {
        case .ready: break
        default: XCTFail("Expected ready")
        }
        switch cancelled {
        case .cancelled: break
        default: XCTFail("Expected cancelled")
        }
        switch failed {
        case .failed: break
        default: XCTFail("Expected failed")
        }
    }
}
