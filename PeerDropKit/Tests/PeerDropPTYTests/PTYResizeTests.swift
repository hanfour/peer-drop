import XCTest
@testable import PeerDropPTY

final class PTYResizeTests: XCTestCase {
    func test_resizeIsVisibleToChild() async throws {
        let exp = expectation(description: "size")
        var got = Data()
        // `stty size` prints "<rows> <cols>" for its controlling terminal.
        let pty = PTYProcess(command: ["/bin/sh", "-c", "sleep 0.3; stty size"])
        pty.onBytes = { d in
            got.append(d)
            if String(decoding: got, as: UTF8.self).contains("24 100") { exp.fulfill() }
        }
        pty.start()
        pty.resize(cols: 100, rows: 24)
        await fulfillment(of: [exp], timeout: 5)
        pty.terminate()
    }
}
