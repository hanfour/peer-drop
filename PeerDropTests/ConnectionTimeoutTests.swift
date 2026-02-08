import XCTest
@testable import PeerDrop

final class ConnectionTimeoutTests: XCTestCase {

    // MARK: - NWConnectionError Tests

    func testTimeoutErrorDescription() {
        let error = NWConnectionError.timeout
        XCTAssertEqual(error.errorDescription, "Connection timed out")
    }

    func testNoDataErrorDescription() {
        let error = NWConnectionError.noData
        XCTAssertEqual(error.errorDescription, "Connection closed by peer")
    }

    func testCancelledErrorDescription() {
        let error = NWConnectionError.cancelled
        XCTAssertEqual(error.errorDescription, "Connection was cancelled")
    }

    func testUnexpectedStateErrorDescription() {
        let error = NWConnectionError.unexpectedState
        XCTAssertEqual(error.errorDescription, "Connection entered an unexpected state")
    }

    func testErrorsAreLocalizedError() {
        let errors: [NWConnectionError] = [.timeout, .noData, .cancelled, .unexpectedState]

        for error in errors {
            // All errors should conform to LocalizedError
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testErrorEquality() {
        XCTAssertEqual(NWConnectionError.timeout, NWConnectionError.timeout)
        XCTAssertEqual(NWConnectionError.noData, NWConnectionError.noData)
        XCTAssertEqual(NWConnectionError.cancelled, NWConnectionError.cancelled)
        XCTAssertEqual(NWConnectionError.unexpectedState, NWConnectionError.unexpectedState)

        XCTAssertNotEqual(NWConnectionError.timeout, NWConnectionError.noData)
        XCTAssertNotEqual(NWConnectionError.cancelled, NWConnectionError.unexpectedState)
    }
}
