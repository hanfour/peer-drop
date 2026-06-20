import XCTest
@testable import PeerDropPTY

final class PTYProcessTests: XCTestCase {
    func test_rawOutputBytesAreDelivered() async throws {
        let exp = expectation(description: "bytes")
        var got = Data()
        let pty = PTYProcess(command: ["/bin/echo", "hello-pty"])
        pty.onBytes = { data in
            got.append(data)
            if String(decoding: got, as: UTF8.self).contains("hello-pty") { exp.fulfill() }
        }
        pty.start()
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertTrue(String(decoding: got, as: UTF8.self).contains("hello-pty"))
        pty.terminate()
    }

    func test_rawInputBytesReachChild() async throws {
        let exp = expectation(description: "echo")
        var got = Data()
        let pty = PTYProcess(command: ["/bin/cat"])
        pty.onBytes = { data in
            got.append(data)
            if String(decoding: got, as: UTF8.self).contains("ping-raw") { exp.fulfill() }
        }
        pty.start()
        pty.writeBytes(Data("ping-raw\n".utf8))
        await fulfillment(of: [exp], timeout: 5)
        pty.terminate()
    }

    func test_exitCallback() async throws {
        let exp = expectation(description: "exit")
        let pty = PTYProcess(command: ["/bin/echo", "x"])
        pty.onExit = { code in XCTAssertEqual(code, 0); exp.fulfill() }
        pty.start()
        await fulfillment(of: [exp], timeout: 5)
    }
}
