import XCTest
@testable import PeerDropSecurity

final class PeerIdentityNotesExchangeTests: XCTestCase {
    func testLegacyHelloDecodesWithoutFlag() throws {
        let legacy = #"{"id":"abc","displayName":"Old","supportsSecureChannel":true}"#
        let id = try JSONDecoder().decode(PeerIdentity.self, from: Data(legacy.utf8))
        XCTAssertFalse(id.supportsNotesExchange)
    }

    func testDefaultsToFalse() {
        XCTAssertFalse(PeerIdentity(displayName: "A").supportsNotesExchange)
        XCTAssertFalse(PeerIdentity(id: "x", displayName: "A").supportsNotesExchange)
    }

    func testFlagRoundTrips() throws {
        let id = PeerIdentity(id: "x", displayName: "A", supportsNotesExchange: true)
        let back = try JSONDecoder().decode(PeerIdentity.self, from: JSONEncoder().encode(id))
        XCTAssertTrue(back.supportsNotesExchange)
    }

    /// An old build's decoder only reads the keys it knows; the new key must be harmless.
    func testOldDecoderIgnoresUnknownKey() throws {
        struct OldShape: Decodable {
            let id: String
            let displayName: String
            let supportsSecureChannel: Bool?
            let isHeadless: Bool?
            let secureChannelVersion: Int?
        }
        let id = PeerIdentity(id: "x", displayName: "A", supportsNotesExchange: true)
        let data = try JSONEncoder().encode(id)
        XCTAssertNoThrow(try JSONDecoder().decode(OldShape.self, from: data))
    }

    func testCopyWithoutNotesExchangeKeepsEverythingElse() {
        let id = PeerIdentity(id: "x", displayName: "A", certificateFingerprint: "cf",
                              identityPublicKey: Data([1, 2]), identityFingerprint: "fp",
                              supportsSecureChannel: true, isHeadless: true,
                              secureChannelVersion: 2, supportsNotesExchange: true)
        let c = id.withoutNotesExchange()
        XCTAssertFalse(c.supportsNotesExchange)
        XCTAssertEqual(c.id, "x")
        XCTAssertEqual(c.displayName, "A")
        XCTAssertEqual(c.certificateFingerprint, "cf")
        XCTAssertEqual(c.identityPublicKey, Data([1, 2]))
        XCTAssertEqual(c.identityFingerprint, "fp")
        XCTAssertTrue(c.supportsSecureChannel)
        XCTAssertTrue(c.isHeadless)
        XCTAssertEqual(c.secureChannelVersion, 2)
    }
}
