// PeerDropKit/Tests/PeerDropCoreTests/DeviceRecordMergeTests.swift
//
// TOFU (trust-on-first-use) pin preservation across DeviceRecord merges.
// Regression coverage for the same-display-name merge silently dropping a
// pinned certificate fingerprint, which reopens a MITM window: an attacker
// broadcasting the victim's display name with a fresh id could wipe the pin.
import XCTest
@testable import PeerDropCore

final class DeviceRecordMergeTests: XCTestCase {

    /// When the primary record has no fingerprint but the record being merged
    /// in does, the fingerprint must survive the merge (mergeByName /
    /// mergeImported paths).
    func test_merge_adoptsFingerprintWhenSelfHasNone() {
        var primary = DeviceRecord(
            id: "A", displayName: "Mac", sourceType: "bonjour",
            lastConnected: Date(timeIntervalSince1970: 100)
        )
        let secondary = DeviceRecord(
            id: "B", displayName: "Mac", sourceType: "bonjour",
            lastConnected: Date(timeIntervalSince1970: 50),
            certificateFingerprint: "FP-B", peerDeviceId: "dev-B"
        )

        primary.merge(with: secondary)

        XCTAssertEqual(primary.certificateFingerprint, "FP-B")
        XCTAssertEqual(primary.peerDeviceId, "dev-B")
    }

    /// An existing pin must not be overwritten by a merge that carries a
    /// different fingerprint — keep the first-seen pin (surfacing a change is a
    /// separate feature; silently replacing it would defeat TOFU).
    func test_merge_keepsExistingPinOverConflicting() {
        var pinned = DeviceRecord(
            id: "A", displayName: "Mac", sourceType: "bonjour",
            lastConnected: Date(timeIntervalSince1970: 100),
            certificateFingerprint: "PINNED", peerDeviceId: "dev-A"
        )
        let other = DeviceRecord(
            id: "A", displayName: "Mac", sourceType: "bonjour",
            lastConnected: Date(timeIntervalSince1970: 200),
            certificateFingerprint: "ATTACKER", peerDeviceId: "dev-X"
        )

        pinned.merge(with: other)

        XCTAssertEqual(pinned.certificateFingerprint, "PINNED")
        XCTAssertEqual(pinned.peerDeviceId, "dev-A")
    }

    /// The security-critical path: a new sighting with the SAME display name
    /// but a NEW id (and no fingerprint) must not drop the pinned fingerprint
    /// held on the prior record.
    @MainActor
    func test_addOrUpdate_sameNameNewId_preservesPinnedFingerprint() {
        UserDefaults.standard.removeObject(forKey: "peerDropDeviceRecords")
        let store = DeviceRecordStore()
        store.replaceAll(with: [
            DeviceRecord(
                id: "old-id", displayName: "PoHan's MacBook", sourceType: "bonjour",
                lastConnected: Date(timeIntervalSince1970: 100),
                certificateFingerprint: "PINNED-FP", peerDeviceId: "dev-old"
            )
        ])

        // Same display name, brand-new id, no fingerprint supplied.
        store.addOrUpdate(id: "new-id", displayName: "PoHan's MacBook",
                          sourceType: "bonjour", host: nil, port: nil)

        let record = store.allRecords().first { $0.displayName == "PoHan's MacBook" }
        XCTAssertEqual(record?.certificateFingerprint, "PINNED-FP",
                       "same-name merge must not silently drop the pinned TOFU fingerprint")
        XCTAssertEqual(record?.peerDeviceId, "dev-old")
    }
}
