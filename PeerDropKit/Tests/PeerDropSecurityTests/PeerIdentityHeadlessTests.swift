import XCTest
@testable import PeerDropSecurity

final class PeerIdentityHeadlessTests: XCTestCase {
    func test_isHeadless_defaultsFalseForNormalPeer() {
        XCTAssertFalse(PeerIdentity(displayName: "Phone").isHeadless)
        XCTAssertFalse(PeerIdentity(id: "x", displayName: "Phone").isHeadless)
    }

    func test_isHeadless_roundTripsThroughCodable() throws {
        let cli = PeerIdentity(id: "x", displayName: "mac · claude", isHeadless: true)
        let data = try JSONEncoder().encode(cli)
        let back = try JSONDecoder().decode(PeerIdentity.self, from: data)
        XCTAssertTrue(back.isHeadless)
    }

    func test_legacyHelloWithoutKey_decodesAsNonHeadless() throws {
        // A v5.x peer's hello payload predates the key; it must decode as a
        // normal (non-headless) user device, not crash.
        let legacy = #"{"id":"abc","displayName":"Old Phone"}"#
        let id = try JSONDecoder().decode(PeerIdentity.self, from: Data(legacy.utf8))
        XCTAssertFalse(id.isHeadless)
    }
}
