import XCTest
import PeerDropProtocol
import CryptoKit
@testable import PeerDrop

final class TrustedContactPeerVersionTests: XCTestCase {

    /// New TrustedContact defaults peerProtocolVersion to nil.
    func test_default_peerProtocolVersion_isNil() throws {
        let contact = makeTestContact()
        XCTAssertNil(contact.peerProtocolVersion)
    }

    /// peerProtocolVersion can be set + round-trips through Codable.
    func test_peerProtocolVersion_roundTrips() throws {
        var contact = makeTestContact()
        contact.peerProtocolVersion = .v5_4_plus
        let data = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(TrustedContact.self, from: data)
        XCTAssertEqual(decoded.peerProtocolVersion, .v5_4_plus)
    }

    /// Legacy serialized blob (no peerProtocolVersion key) must still decode.
    /// Existing v5.0–v5.3.x contacts on disk fall into this path.
    func test_legacy_serialization_decodes_with_nil() throws {
        let legacyJSON = makeLegacyContactDict()
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let decoded = try JSONDecoder().decode(TrustedContact.self, from: data)
        XCTAssertNil(decoded.peerProtocolVersion)
    }

    /// All three PeerVersion values serialize round-trip cleanly.
    func test_allPeerVersions_roundTrip() throws {
        for version: PeerVersion in [.legacy, .v5_4_plus, .unknown] {
            var contact = makeTestContact()
            contact.peerProtocolVersion = version
            let data = try JSONEncoder().encode(contact)
            let decoded = try JSONDecoder().decode(TrustedContact.self, from: data)
            XCTAssertEqual(decoded.peerProtocolVersion, version,
                           "round-trip failed for \(version)")
        }
    }

    /// Sanity smoke: a TrustedContact whose peerProtocolVersion was set from
    /// envelope.protocolVersion=1 round-trips and retains .v5_4_plus.
    /// (The full ConnectionManager.handleRemoteMessage path is exercised
    /// indirectly by RelayTrustGateIntegrationTests; this test pins the
    /// mapping behavior at the smoke level.)
    func test_envelope_version_maps_to_contact_version() {
        XCTAssertEqual(PeerVersion.from(envelopeProtocolVersion: nil), .legacy)
        XCTAssertEqual(PeerVersion.from(envelopeProtocolVersion: 1), .v5_4_plus)
        XCTAssertEqual(PeerVersion.from(envelopeProtocolVersion: 2), .unknown)
    }

    // MARK: - Helpers

    private func makeTestContact() -> TrustedContact {
        TrustedContact(
            id: UUID(),
            displayName: "Test Peer",
            identityPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            trustLevel: .unknown,
            firstConnected: Date()
        )
    }

    /// Build a JSON dict containing ALL pre-PR7 required fields but NO
    /// peerProtocolVersion. Mirrors what a v5.0–v5.3.x persisted contact looks like.
    private func makeLegacyContactDict() -> [String: Any] {
        let keyData = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        return [
            "id": UUID().uuidString,
            "displayName": "Legacy Peer",
            "identityPublicKey": keyData.base64EncodedString(),
            "trustLevel": "unknown",
            "firstConnected": Date().timeIntervalSinceReferenceDate,
            "isBlocked": false,
            "keyHistory": [] as [[String: Any]]
        ]
    }
}
