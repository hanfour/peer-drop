import XCTest
@testable import PeerDrop

final class CallProviderTests: XCTestCase {
    func test_callEndReasonHasFourCases() {
        // Pin the cross-platform enum surface. Changes here mean CallKitManager
        // and (future M3) MacCallProvider must update their adapters.
        let allCases: [CallEndReason] = [.remoteEnded, .declinedElsewhere, .failed, .unanswered]
        XCTAssertEqual(allCases.count, 4)
    }
}
