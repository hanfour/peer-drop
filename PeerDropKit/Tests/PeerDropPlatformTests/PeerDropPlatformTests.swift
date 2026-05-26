import XCTest
@testable import PeerDropPlatform

final class PeerDropPlatformTests: XCTestCase {
    func test_moduleIsLinkable() {
        XCTAssertNotNil(PeerDropPlatform.self)
    }
}
