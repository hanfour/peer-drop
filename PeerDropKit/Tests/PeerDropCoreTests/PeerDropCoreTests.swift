// PeerDropKit/Tests/PeerDropCoreTests/PeerDropCoreTests.swift
import XCTest
@testable import PeerDropCore

final class PeerDropCoreTests: XCTestCase {
    /// Smoke-check: confirm a key public type from PeerDropCore links
    /// when imported via the SPM module boundary. The M1d-1 placeholder
    /// enum was deleted in M1d-5 once real types migrated into the module.
    func test_moduleIsLinkable() {
        XCTAssertEqual(ConnectionRecommendation.useRelayCode, .useRelayCode)
    }
}
