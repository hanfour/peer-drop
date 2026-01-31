import XCTest
@testable import PeerDrop

final class StateMachineTests: XCTestCase {

    // MARK: - Valid Transitions

    func testIdleToDiscovering() {
        let state = ConnectionState.idle
        XCTAssertTrue(state.canTransition(to: .discovering))
    }

    func testDiscoveringToPeerFound() {
        let state = ConnectionState.discovering
        XCTAssertTrue(state.canTransition(to: .peerFound))
    }

    func testDiscoveringToIncomingRequest() {
        let state = ConnectionState.discovering
        XCTAssertTrue(state.canTransition(to: .incomingRequest))
    }

    func testPeerFoundToRequesting() {
        let state = ConnectionState.peerFound
        XCTAssertTrue(state.canTransition(to: .requesting))
    }

    func testRequestingToConnecting() {
        let state = ConnectionState.requesting
        XCTAssertTrue(state.canTransition(to: .connecting))
    }

    func testRequestingToRejected() {
        let state = ConnectionState.requesting
        XCTAssertTrue(state.canTransition(to: .rejected))
    }

    func testConnectingToConnected() {
        let state = ConnectionState.connecting
        XCTAssertTrue(state.canTransition(to: .connected))
    }

    func testConnectedToTransferring() {
        let state = ConnectionState.connected
        XCTAssertTrue(state.canTransition(to: .transferring))
    }

    func testConnectedToVoiceCall() {
        let state = ConnectionState.connected
        XCTAssertTrue(state.canTransition(to: .voiceCall))
    }

    func testConnectedToDisconnected() {
        let state = ConnectionState.connected
        XCTAssertTrue(state.canTransition(to: .disconnected))
    }

    func testTransferringToConnected() {
        let state = ConnectionState.transferring(progress: 0.5)
        XCTAssertTrue(state.canTransition(to: .connected))
    }

    func testVoiceCallToConnected() {
        let state = ConnectionState.voiceCall
        XCTAssertTrue(state.canTransition(to: .connected))
    }

    func testDisconnectedToIdle() {
        let state = ConnectionState.disconnected
        XCTAssertTrue(state.canTransition(to: .idle))
    }

    func testFailedToDiscovering() {
        let state = ConnectionState.failed(reason: "error")
        XCTAssertTrue(state.canTransition(to: .discovering))
    }

    // MARK: - Invalid Transitions

    func testIdleToConnected() {
        let state = ConnectionState.idle
        XCTAssertFalse(state.canTransition(to: .connected))
    }

    func testDiscoveringToConnected() {
        let state = ConnectionState.discovering
        XCTAssertFalse(state.canTransition(to: .connected))
    }

    func testConnectedToDiscovering() {
        let state = ConnectionState.connected
        XCTAssertFalse(state.canTransition(to: .discovering))
    }

    func testTransferringToDiscovering() {
        let state = ConnectionState.transferring(progress: 0.5)
        XCTAssertFalse(state.canTransition(to: .discovering))
    }

    // MARK: - Equality

    func testStateEquality() {
        XCTAssertEqual(ConnectionState.idle, ConnectionState.idle)
        XCTAssertEqual(ConnectionState.transferring(progress: 0.5), ConnectionState.transferring(progress: 0.5))
        XCTAssertNotEqual(ConnectionState.transferring(progress: 0.5), ConnectionState.transferring(progress: 0.8))
        XCTAssertEqual(ConnectionState.failed(reason: "err"), ConnectionState.failed(reason: "err"))
        XCTAssertNotEqual(ConnectionState.idle, ConnectionState.connected)
    }
}
