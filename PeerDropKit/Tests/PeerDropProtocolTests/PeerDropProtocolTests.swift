// PeerDropKit/Tests/PeerDropProtocolTests/PeerDropProtocolTests.swift
import XCTest
@testable import PeerDropProtocol

final class PeerDropProtocolTests: XCTestCase {
    func test_moduleIsLinkable() {
        // Real test migration happens later. For now, verify a real type
        // from the module is reachable from the test target.
        XCTAssertNotNil(MessageType.self)
    }
}
