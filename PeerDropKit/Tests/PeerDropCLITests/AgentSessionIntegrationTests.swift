import XCTest
@testable import peerdrop_cli
@testable import PeerDropCore
@testable import PeerDropProtocol
@testable import PeerDropSecurity

final class AgentSessionIntegrationTests: XCTestCase {
    @MainActor
    func test_inboundTextReachesChildAndOutputBroadcasts() async throws {
        let cm = ConnectionManager()
        let store = cm.trustedContactStore

        let lock = NSLock()
        var got = ""
        let echoed = expectation(description: "token echoed back out through the bridge")

        // `cat` echoes its stdin to stdout (PTY echo is disabled, so this is cat's
        // own output, not terminal echo).
        let bridge = ProcessBridge(command: ["/bin/cat"], idle: .milliseconds(80))
        // #166: only a peer passing the input gate may reach the child. The gate's
        // real facts need a secured, verified connection (covered by
        // InputGateFactsTests); here we authorise peer-1 so the round trip runs.
        let session = AgentSession(bridge: bridge, connectionManager: cm, store: store,
                                   isAuthorized: { $0 == "peer-1" })
        bridge.onMessage = { [weak session] text in
            lock.lock()
            got += text
            let done = got.contains("roundtrip-XYZ")
            lock.unlock()
            session?.broadcast(text)   // exercises the broadcast leg (no connected peer → harmless)
            if done { echoed.fulfill() }
        }
        session.wire()
        bridge.start()

        // Simulate an inbound textMessage from a peer.
        let payload = TextMessagePayload(text: "roundtrip-XYZ", senderName: "iPhone")
        let msg = try PeerMessage.textMessage(payload, senderID: "peer-1")
        cm.dispatchTextForTesting(msg, from: "peer-1")

        await fulfillment(of: [echoed], timeout: 5)
        bridge.terminate()
    }
}
