import XCTest
import PeerDropProtocol
@testable import PeerDrop

final class PeerVersionMappingTests: XCTestCase {

    func test_nil_maps_to_legacy() {
        XCTAssertEqual(PeerVersion.from(envelopeProtocolVersion: nil), .legacy)
    }

    func test_one_maps_to_v5_4_plus() {
        XCTAssertEqual(PeerVersion.from(envelopeProtocolVersion: 1), .v5_4_plus)
    }

    func test_zero_maps_to_unknown() {
        XCTAssertEqual(PeerVersion.from(envelopeProtocolVersion: 0), .unknown)
    }

    func test_future_versions_map_to_unknown() {
        XCTAssertEqual(PeerVersion.from(envelopeProtocolVersion: 2), .unknown)
        XCTAssertEqual(PeerVersion.from(envelopeProtocolVersion: 99), .unknown)
        XCTAssertEqual(PeerVersion.from(envelopeProtocolVersion: 255), .unknown)
    }
}
