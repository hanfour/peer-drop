// PeerDropKit/Tests/PeerDropSecurityTests/PeerDropSecurityTests.swift
import XCTest
@testable import PeerDropSecurity

final class PeerDropSecurityTests: XCTestCase {
    /// Placeholder. Real tests for PeerDropSecurity consumers (PeerIdentity, ChatDataEncryptor, Double Ratchet, SAS) migrate
    /// here in M1d-2 alongside the source files. This single trivial test
    /// ensures `swift test` can find + run a test target.
    func test_moduleIsLinkable() {
        // PeerDropSecurity is currently `public enum PeerDropSecurity {}` — verify
        // the test target can reference it.
        XCTAssertNotNil(PeerDropSecurity.self)
    }
}
