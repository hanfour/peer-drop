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

        var broadcast: [String] = []
        // `cat` echoes its stdin to stdout, so an inbound line comes back out.
        let bridge = ProcessBridge(command: ["/bin/cat"], idle: .milliseconds(80))
        let session = AgentSession(bridge: bridge, connectionManager: cm, store: store)
        bridge.onMessage = { text in
            broadcast.append(text)
            session.broadcast(text)
        }
        session.wire()
        bridge.start()

        // Simulate an inbound textMessage from a peer.
        let payload = TextMessagePayload(text: "roundtrip-XYZ", senderName: "iPhone")
        let msg = try PeerMessage.textMessage(payload, senderID: "peer-1")
        cm.dispatchTextForTesting(msg, from: "peer-1")

        // Wait for the child to echo it back through the segmenter.
        try await waitUntil(timeout: 5) { broadcast.contains { $0.contains("roundtrip-XYZ") } }
        XCTAssertTrue(broadcast.contains { $0.contains("roundtrip-XYZ") })
        bridge.terminate()
    }

    private func waitUntil(timeout: TimeInterval, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
