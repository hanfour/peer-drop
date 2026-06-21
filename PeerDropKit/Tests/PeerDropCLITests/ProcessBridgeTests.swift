import XCTest
@testable import peerdrop_cli

final class ProcessBridgeTests: XCTestCase {
    func test_echoCommandProducesOutputMessage() async throws {
        let exp = expectation(description: "output")
        var got = ""
        let bridge = ProcessBridge(
            command: ["/bin/echo", "hello-bridge"],
            idle: .milliseconds(80)
        )
        bridge.onMessage = { text in
            got += text
            if got.contains("hello-bridge") { exp.fulfill() }
        }
        bridge.start()
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertTrue(got.contains("hello-bridge"))
        bridge.terminate()
    }

    func test_inputIsWrittenToChild() async throws {
        let exp = expectation(description: "roundtrip")
        var got = ""
        let bridge = ProcessBridge(
            command: ["/bin/cat"],
            idle: .milliseconds(80)
        )
        bridge.onMessage = { text in
            got += text
            if got.contains("ping-123") { exp.fulfill() }
        }
        bridge.start()
        bridge.send("ping-123")
        await fulfillment(of: [exp], timeout: 5)
        bridge.terminate()
    }

    func test_exitCallbackFiresWhenChildEnds() async throws {
        let exp = expectation(description: "exit")
        let bridge = ProcessBridge(
            command: ["/bin/echo", "bye"],
            idle: .milliseconds(80)
        )
        bridge.onExit = { code in
            XCTAssertEqual(code, 0)
            exp.fulfill()
        }
        bridge.start()
        await fulfillment(of: [exp], timeout: 5)
    }

    func test_restartRelaunchesProcess() async throws {
        let exits = expectation(description: "two exits")
        exits.expectedFulfillmentCount = 2
        let bridge = ProcessBridge(
            command: ["/bin/echo", "again"],
            idle: .milliseconds(80)
        )
        // Trigger the second start() from within the first onExit to avoid
        // timing sensitivity: we know the first run has fully exited before
        // relaunching, and onExit must fire a second time for the relaunch.
        let relaunched = expectation(description: "relaunched")
        relaunched.expectedFulfillmentCount = 1
        var exitCount = 0
        bridge.onExit = { code in
            XCTAssertEqual(code, 0)
            exits.fulfill()
            exitCount += 1
            if exitCount == 1 {
                // Hop off the termination queue before calling start() again.
                DispatchQueue.global().async {
                    bridge.start()
                    relaunched.fulfill()
                }
            }
        }
        bridge.start()
        await fulfillment(of: [relaunched, exits], timeout: 8)
        bridge.terminate()
    }
}
