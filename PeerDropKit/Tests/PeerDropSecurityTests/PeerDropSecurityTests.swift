// PeerDropKit/Tests/PeerDropSecurityTests/PeerDropSecurityTests.swift
import XCTest
@testable import PeerDropSecurity

final class PeerDropSecurityTests: XCTestCase {
    func test_moduleIsLinkable() {
        XCTAssertNotNil(SecurityPolicy.self)
    }
}
