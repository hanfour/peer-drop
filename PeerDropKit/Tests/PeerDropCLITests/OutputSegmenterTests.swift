import XCTest
@testable import peerdrop_cli

final class OutputSegmenterTests: XCTestCase {
    func test_flushesAfterIdle() async {
        var messages: [String] = []
        let seg = OutputSegmenter(idle: .milliseconds(50), cap: 1 << 20) { messages.append($0) }
        seg.ingest(Data("ls output".utf8))
        XCTAssertTrue(messages.isEmpty)            // not yet idle
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(messages, ["ls output"])    // flushed after idle
    }

    func test_capForcesImmediateFlush() {
        var messages: [String] = []
        let seg = OutputSegmenter(idle: .seconds(99), cap: 4) { messages.append($0) }
        seg.ingest(Data("12345".utf8))             // exceeds cap of 4
        XCTAssertEqual(messages, ["12345"])
    }

    func test_stripsAnsiBeforeEmitting() async {
        var messages: [String] = []
        let seg = OutputSegmenter(idle: .milliseconds(50), cap: 1 << 20) { messages.append($0) }
        seg.ingest(Data("\u{1B}[32mok\u{1B}[0m".utf8))
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(messages, ["ok"])
    }
}
