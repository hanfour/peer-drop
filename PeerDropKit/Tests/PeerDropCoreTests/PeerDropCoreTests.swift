// PeerDropKit/Tests/PeerDropCoreTests/PeerDropCoreTests.swift
import XCTest
@testable import PeerDropCore

final class PeerDropCoreTests: XCTestCase {
    /// Placeholder. Real tests for PeerDropCore consumers (ConnectionManager, ChatManager, etc.) migrate
    /// here in M1d-4 alongside the source files. This single trivial test
    /// ensures `swift test` can find + run a test target.
    func test_moduleIsLinkable() {
        // PeerDropCore is currently `public enum PeerDropCore {}` — verify
        // the test target can reference it.
        XCTAssertNotNil(PeerDropCore.self)
    }
}
