import XCTest
@testable import webterm
@testable import PeerDropPTY

final class TerminalSessionTests: XCTestCase {
    /// Verify that env vars passed to `TmuxControl.createIfNeeded` are visible in the
    /// session command. Uses `-e KEY=VALUE` tmux new-session flags (tmux 3.x).
    func test_createIfNeeded_envVarsVisibleInSession() async throws {
        let id = "webterm-envtest-\(ProcessInfo.processInfo.processIdentifier)"
        defer { _ = try? TmuxControl.kill(id) }

        try TmuxControl.createIfNeeded(
            id: id,
            command: "printf \"VAL=$WT_ENV_TEST\"; sleep 20",
            cwd: nil,
            env: ["WT_ENV_TEST": "hello123"]
        )

        let exp = expectation(description: "env var visible in session output")
        exp.assertForOverFulfill = false
        let session = TerminalSession(id: id)
        var received = Data()
        _ = session.addClient { bytes in
            received.append(bytes)
            if String(decoding: received, as: UTF8.self).contains("VAL=hello123") { exp.fulfill() }
        }
        session.start()
        await fulfillment(of: [exp], timeout: 10)
        session.detach()
    }

    func test_attachReceivesOutputAndSurvivesReattach() async throws {
        let id = "webtermtest-\(ProcessInfo.processInfo.processIdentifier)"
        defer { _ = try? TmuxControl.kill(id) }

        // Create a detached tmux session printing a marker then sleeping.
        try TmuxControl.createIfNeeded(id: id, command: "echo MARKER-OUT; sleep 30", cwd: nil)

        let exp1 = expectation(description: "marker via first attach")
        exp1.assertForOverFulfill = false
        let s1 = TerminalSession(id: id)
        var got1 = Data()
        let c1 = s1.addClient { bytes in
            got1.append(bytes)
            if String(decoding: got1, as: UTF8.self).contains("MARKER-OUT") { exp1.fulfill() }
        }
        s1.start()
        await fulfillment(of: [exp1], timeout: 5)
        s1.removeClient(c1); s1.detach()   // detach — tmux session keeps running

        // Reattach with a NEW session object → tmux redraws → marker visible again.
        let exp2 = expectation(description: "marker via reattach")
        exp2.assertForOverFulfill = false
        let s2 = TerminalSession(id: id)
        var got2 = Data()
        _ = s2.addClient { bytes in
            got2.append(bytes)
            if String(decoding: got2, as: UTF8.self).contains("MARKER-OUT") { exp2.fulfill() }
        }
        s2.start()
        await fulfillment(of: [exp2], timeout: 5)
        s2.detach()
    }
}
