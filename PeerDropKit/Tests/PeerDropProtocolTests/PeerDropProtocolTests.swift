// PeerDropKit/Tests/PeerDropProtocolTests/PeerDropProtocolTests.swift
import XCTest
@testable import PeerDropProtocol

final class PeerDropProtocolTests: XCTestCase {
    /// Placeholder. Real tests for PeerDropProtocol consumers (wire format, message envelope, version negotiation) migrate
    /// here in M1d-2 alongside the source files. This single trivial test
    /// ensures `swift test` can find + run a test target.
    func test_moduleIsLinkable() {
        // PeerDropProtocol is currently `public enum PeerDropProtocol {}` — verify
        // the test target can reference it.
        XCTAssertNotNil(PeerDropProtocol.self)
    }
}
