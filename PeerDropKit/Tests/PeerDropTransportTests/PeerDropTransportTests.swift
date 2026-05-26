// PeerDropKit/Tests/PeerDropTransportTests/PeerDropTransportTests.swift
import XCTest
@testable import PeerDropTransport

final class PeerDropTransportTests: XCTestCase {
    /// Placeholder. Real tests for PeerDropTransport consumers (Bonjour, PeerConnection, RelaySession, WebRTC, voice transport pieces) migrate
    /// here in M1d-3 alongside the source files. This single trivial test
    /// ensures `swift test` can find + run a test target.
    func test_moduleIsLinkable() {
        // PeerDropTransport is currently `public enum PeerDropTransport {}` — verify
        // the test target can reference it.
        XCTAssertNotNil(PeerDropTransport.self)
    }
}
