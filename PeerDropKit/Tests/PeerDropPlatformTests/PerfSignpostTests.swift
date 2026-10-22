import XCTest
@testable import PeerDropPlatform

final class PerfSignpostTests: XCTestCase {
    override func setUp() { PerfSignpost.reset() }

    @MainActor
    func testSectionOnMainThreadIsCountedAsMain() {
        let value = PerfSignpost.measure(.fileHash) { 42 }
        XCTAssertEqual(value, 42)
        let s = PerfSignpost.snapshot()[.fileHash]
        XCTAssertEqual(s?.count, 1)
        XCTAssertEqual(s?.mainThreadCount, 1)
    }

    func testSectionOffMainThreadIsNotCountedAsMain() async {
        await Task.detached { PerfSignpost.measure(.proofOfWork) { () -> Void in } }.value
        let s = PerfSignpost.snapshot()[.proofOfWork]
        XCTAssertEqual(s?.count, 1)
        XCTAssertEqual(s?.mainThreadCount, 0)
        XCTAssertEqual(s?.mainThreadSeconds, 0)
    }

    func testRethrowsAndStillRecords() {
        struct Boom: Error {}
        XCTAssertThrowsError(try PerfSignpost.measure(.chatLoad) { throw Boom() })
        XCTAssertEqual(PerfSignpost.snapshot()[.chatLoad]?.count, 1)
    }

    func testReportListsOnlyPathsWithSamples() {
        PerfSignpost.measure(.chatPersist) {}
        let report = PerfSignpost.report()
        XCTAssertTrue(report.contains("chatPersist"))
        XCTAssertFalse(report.contains("proofOfWork"))
    }
}
