import XCTest
@testable import PeerDropSecurity

/// #170 compat: the hello carries the peer's secure-channel protocol version
/// so a receiver knows whether the peer can be held to "no plaintext after
/// the channel is up". Absent (v5.6.0 and earlier) means 1.
final class PeerIdentitySecureChannelVersionTests: XCTestCase {
    func test_thisBuildAdvertisesVersion2() {
        XCTAssertEqual(PeerIdentity.currentSecureChannelVersion, 2)
        XCTAssertEqual(PeerIdentity(id: "x", displayName: "Phone").secureChannelVersion, 2)
    }

    func test_versionRoundTripsThroughCodable() throws {
        for v in [1, 2, 7] {
            let id = PeerIdentity(id: "x", displayName: "Phone", secureChannelVersion: v)
            let back = try JSONDecoder().decode(PeerIdentity.self, from: JSONEncoder().encode(id))
            XCTAssertEqual(back.secureChannelVersion, v)
        }
    }

    func test_legacyHelloWithoutKey_decodesAsVersion1() throws {
        let legacy = #"{"id":"abc","displayName":"Old Phone","supportsSecureChannel":true}"#
        let id = try JSONDecoder().decode(PeerIdentity.self, from: Data(legacy.utf8))
        XCTAssertEqual(id.secureChannelVersion, 1)
    }

    func test_encodedHello_containsTheKey() throws {
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(PeerIdentity(id: "x", displayName: "P"))) as? [String: Any]
        XCTAssertEqual(json?["secureChannelVersion"] as? Int, 2)
    }
}
