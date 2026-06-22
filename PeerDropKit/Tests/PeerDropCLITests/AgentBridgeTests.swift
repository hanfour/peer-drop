import XCTest
@testable import peerdrop_cli

final class AgentBridgeTests: XCTestCase {
    func test_arguments_includePrintContinueFormatAndPermission() {
        let args = AgentBridge.arguments(
            for: "how does X work?",
            baseCommand: ["claude"],
            permissionMode: "plan"
        )
        XCTAssertEqual(
            args,
            ["claude", "-p", "how does X work?",
             "--continue", "--output-format", "text", "--permission-mode", "plan"]
        )
    }

    func test_arguments_honourCustomBaseCommand() {
        let args = AgentBridge.arguments(
            for: "hi",
            baseCommand: ["claude", "--model", "opus"],
            permissionMode: "bypassPermissions"
        )
        XCTAssertEqual(args.prefix(3), ["claude", "--model", "opus"].prefix(3))
        XCTAssertEqual(args.suffix(2), ["--permission-mode", "bypassPermissions"].suffix(2))
        XCTAssertTrue(args.contains("hi"))
    }

    func test_send_runsBaseCommandAndEmitsStdout() {
        // Use /bin/echo as a stand-in agent: it echoes the argv we'd pass to
        // claude, so the captured stdout proves the run→capture→emit pipeline.
        let exp = expectation(description: "reply")
        var got = ""
        let bridge = AgentBridge(baseCommand: ["/bin/echo"], permissionMode: "plan")
        bridge.onMessage = { got = $0; exp.fulfill() }
        bridge.start()
        bridge.send("hello-agent")
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(got.contains("hello-agent"), "got: \(got)")
        bridge.terminate()
    }

    func test_send_emptyPrompt_doesNothing() {
        var emitted = false
        let bridge = AgentBridge(baseCommand: ["/bin/echo"], permissionMode: "plan")
        bridge.onMessage = { _ in emitted = true }
        bridge.send("   \n  ")
        // Give the queue a beat; nothing should be scheduled.
        let pause = expectation(description: "pause")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { pause.fulfill() }
        wait(for: [pause], timeout: 2)
        XCTAssertFalse(emitted)
    }

    /// Live end-to-end against the real `claude` CLI. Gated behind an env var
    /// so the normal suite never spends tokens; run with
    /// `PEERDROP_LIVE_AGENT=1 swift test --filter test_live_realClaude`.
    func test_live_realClaude_emitsCleanPlainTextReply() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PEERDROP_LIVE_AGENT"] == "1",
            "set PEERDROP_LIVE_AGENT=1 to exercise the real claude CLI"
        )
        let exp = expectation(description: "claude reply")
        var got = ""
        let bridge = AgentBridge(baseCommand: ["claude"], permissionMode: "plan")
        bridge.onMessage = { got = $0; exp.fulfill() }
        bridge.send("Reply with exactly one word: pong")
        wait(for: [exp], timeout: 120)
        XCTAssertFalse(got.isEmpty, "expected a reply")
        XCTAssertFalse(got.contains("\u{1B}"), "reply must be plain text, no ANSI escapes")
        print("LIVE CLAUDE REPLY >>> \(got)")
    }

    func test_send_nonZeroExit_emitsErrorBubble() {
        let exp = expectation(description: "err")
        var got = ""
        let bridge = AgentBridge(baseCommand: ["/usr/bin/false"], permissionMode: "plan")
        bridge.onMessage = { got = $0; exp.fulfill() }
        bridge.send("anything")
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(got.contains("agent exited"), "got: \(got)")
        bridge.terminate()
    }
}
