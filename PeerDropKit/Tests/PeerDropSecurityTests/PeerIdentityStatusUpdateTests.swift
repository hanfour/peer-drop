import XCTest
@testable import PeerDropSecurity

/// Project F2: the HELLO capability flag for `.statusUpdate`. An older build
/// drops the connection on an unknown `MessageType`, so the flag must decode
/// as `false` when absent and must survive every identity copy the HELLO
/// paths make (relay / rendezvous HELLOs use `withoutNotesExchange()`).
final class PeerIdentityStatusUpdateTests: XCTestCase {
    func testAbsentKeyDecodesFalse() throws {
        let legacy = #"{"id":"abc","displayName":"Old","supportsSecureChannel":true,"supportsNotesExchange":true}"#
        let id = try JSONDecoder().decode(PeerIdentity.self, from: Data(legacy.utf8))
        XCTAssertFalse(id.supportsStatusUpdate)
        XCTAssertTrue(id.supportsNotesExchange)
        XCTAssertFalse(PeerIdentity(displayName: "A").supportsStatusUpdate)
        XCTAssertFalse(PeerIdentity(id: "x", displayName: "A").supportsStatusUpdate)
    }

    func testRoundTrip() throws {
        for flag in [true, false] {
            let id = PeerIdentity(id: "x", displayName: "A", supportsStatusUpdate: flag)
            let back = try JSONDecoder().decode(PeerIdentity.self, from: JSONEncoder().encode(id))
            XCTAssertEqual(back.supportsStatusUpdate, flag)
        }
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(PeerIdentity(id: "x", displayName: "A", supportsStatusUpdate: true))) as? [String: Any]
        XCTAssertEqual(json?["supportsStatusUpdate"] as? Bool, true)
    }

    func testWithoutStatusUpdateClearsOnlyThatFlag() {
        let id = PeerIdentity(id: "x", displayName: "A", certificateFingerprint: "cf",
                              identityPublicKey: Data([1, 2]), identityFingerprint: "fp",
                              supportsSecureChannel: true, isHeadless: true,
                              secureChannelVersion: 2, supportsNotesExchange: true,
                              supportsStatusUpdate: true)
        let c = id.withoutStatusUpdate()
        XCTAssertFalse(c.supportsStatusUpdate)
        XCTAssertTrue(c.supportsNotesExchange)
        XCTAssertEqual(c.id, "x")
        XCTAssertEqual(c.displayName, "A")
        XCTAssertEqual(c.certificateFingerprint, "cf")
        XCTAssertEqual(c.identityPublicKey, Data([1, 2]))
        XCTAssertEqual(c.identityFingerprint, "fp")
        XCTAssertTrue(c.supportsSecureChannel)
        XCTAssertTrue(c.isHeadless)
        XCTAssertEqual(c.secureChannelVersion, 2)
    }

    /// Relay and rendezvous HELLOs strip the notes flag; that must not also
    /// silently strip the status-update flag.
    func testWithoutNotesExchangeKeepsStatusUpdate() {
        let on = PeerIdentity(id: "x", displayName: "A", supportsNotesExchange: true, supportsStatusUpdate: true)
        XCTAssertTrue(on.withoutNotesExchange().supportsStatusUpdate)
        XCTAssertFalse(on.withoutNotesExchange().supportsNotesExchange)
        let off = PeerIdentity(id: "x", displayName: "A", supportsNotesExchange: true, supportsStatusUpdate: false)
        XCTAssertFalse(off.withoutNotesExchange().supportsStatusUpdate)
    }

    /// Advertised even by headless CLI peers (a file store marks the CLI):
    /// they are receive-only, and cross-version runs rely on them.
    @MainActor
    func testLocalAdvertisesStatusUpdate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pisu-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: dir, namespace: "pisutest")
        defer {
            PeerDropPersistence.fileStore = nil
            try? FileManager.default.removeItem(at: dir)
        }
        let local = PeerIdentity.local()
        XCTAssertTrue(local.isHeadless)
        XCTAssertTrue(local.supportsStatusUpdate)
        XCTAssertTrue(local.withoutNotesExchange().supportsStatusUpdate)
    }
}
