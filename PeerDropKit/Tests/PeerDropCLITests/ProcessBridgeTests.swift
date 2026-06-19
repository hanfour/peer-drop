import XCTest
@testable import peerdrop_cli

final class ProcessBridgeTests: XCTestCase {
    func test_echoCommandProducesOutputMessage() async throws {
        let exp = expectation(description: "output")
        var got = ""
        let bridge = try ProcessBridge(
            command: ["/bin/echo", "hello-bridge"],
            idle: .milliseconds(80)
        ) { text in
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
        let bridge = try ProcessBridge(
            command: ["/bin/cat"],
            idle: .milliseconds(80)
        ) { text in
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
        let bridge = try ProcessBridge(
            command: ["/bin/echo", "bye"],
            idle: .milliseconds(80)
        ) { _ in }
        bridge.onExit = { code in
            XCTAssertEqual(code, 0)
            exp.fulfill()
        }
        bridge.start()
        await fulfillment(of: [exp], timeout: 5)
    }
}
