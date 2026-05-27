// PeerDropKit/Tests/PeerDropTransportTests/PeerDropTransportTests.swift
import XCTest
@testable import PeerDropTransport

final class PeerDropTransportTests: XCTestCase {
    /// Placeholder. Real Transport tests migrate from PeerDropTests into
    /// this target in Task 8. This trivial test ensures `swift test` can
    /// find and run a test target after the placeholder enum was deleted.
    func test_transferRecord_publicConstruction() {
        let record = TransferRecord(
            fileName: "test.txt",
            fileSize: 100,
            direction: .sent,
            timestamp: Date(),
            success: true
        )
        XCTAssertEqual(record.fileName, "test.txt")
        XCTAssertEqual(record.fileSize, 100)
    }
}
