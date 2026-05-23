import XCTest
import CryptoKit
@testable import PeerDrop

final class X3DHOPKFailClosedTests: XCTestCase {

    private func makeFreshKeys() -> (alice: (ik: Curve25519.KeyAgreement.PrivateKey, ek: Curve25519.KeyAgreement.PrivateKey),
                                       bob: (ik: Curve25519.KeyAgreement.PrivateKey, spk: Curve25519.KeyAgreement.PrivateKey, opk: Curve25519.KeyAgreement.PrivateKey)) {
        return (
            alice: (Curve25519.KeyAgreement.PrivateKey(), Curve25519.KeyAgreement.PrivateKey()),
            bob: (Curve25519.KeyAgreement.PrivateKey(), Curve25519.KeyAgreement.PrivateKey(), Curve25519.KeyAgreement.PrivateKey())
        )
    }

    func test_legacy_peer_with_opkNil_proceeds() throws {
        let k = makeFreshKeys()
        let result = try X3DH.initiatorKeyAgreement(
            myIdentityKey: k.alice.ik,
            myEphemeralKey: k.alice.ek,
            theirIdentityKey: k.bob.ik.publicKey,
            theirSignedPreKey: k.bob.spk.publicKey,
            theirOneTimePreKey: nil,
            peerVersion: .legacy,
            policy: .bundledDefault,
            metrics: nil
        )
        XCTAssertFalse(result.rootKey.withUnsafeBytes { Data($0) }.isEmpty,
                       "legacy peer should still succeed without DH4")
    }

    func test_v5_4_peer_with_opkNil_throws_opkExhausted() throws {
        let k = makeFreshKeys()
        XCTAssertThrowsError(
            try X3DH.initiatorKeyAgreement(
                myIdentityKey: k.alice.ik,
                myEphemeralKey: k.alice.ek,
                theirIdentityKey: k.bob.ik.publicKey,
                theirSignedPreKey: k.bob.spk.publicKey,
                theirOneTimePreKey: nil,
                peerVersion: .v5_4_plus,
                policy: .bundledDefault,
                metrics: nil
            )
        ) { error in
            guard case X3DH.InitiationError.opkExhausted = error else {
                return XCTFail("expected .opkExhausted, got \(error)")
            }
        }
    }

    func test_unknown_peer_with_opkNil_throws_opkExhausted() throws {
        let k = makeFreshKeys()
        XCTAssertThrowsError(
            try X3DH.initiatorKeyAgreement(
                myIdentityKey: k.alice.ik,
                myEphemeralKey: k.alice.ek,
                theirIdentityKey: k.bob.ik.publicKey,
                theirSignedPreKey: k.bob.spk.publicKey,
                theirOneTimePreKey: nil,
                peerVersion: .unknown,
                policy: .bundledDefault,
                metrics: nil
            )
        )
    }

    func test_opk_present_succeeds_for_any_peerVersion() throws {
        let k = makeFreshKeys()
        for version: PeerVersion in [.legacy, .v5_4_plus, .unknown] {
            let result = try X3DH.initiatorKeyAgreement(
                myIdentityKey: k.alice.ik,
                myEphemeralKey: k.alice.ek,
                theirIdentityKey: k.bob.ik.publicKey,
                theirSignedPreKey: k.bob.spk.publicKey,
                theirOneTimePreKey: k.bob.opk.publicKey,   // present → normal X3DH
                peerVersion: version,
                policy: .bundledDefault,
                metrics: nil
            )
            XCTAssertFalse(result.rootKey.withUnsafeBytes { Data($0) }.isEmpty,
                           "OPK-present path should always succeed for \(version)")
        }
    }

    func test_telemetry_legacy_opkMissing_only() throws {
        let k = makeFreshKeys()
        let metrics = CryptoHardeningMetrics()
        _ = try X3DH.initiatorKeyAgreement(
            myIdentityKey: k.alice.ik,
            myEphemeralKey: k.alice.ek,
            theirIdentityKey: k.bob.ik.publicKey,
            theirSignedPreKey: k.bob.spk.publicKey,
            theirOneTimePreKey: nil,
            peerVersion: .legacy,
            policy: .bundledDefault,
            metrics: metrics
        )
        let snap = metrics.snapshot()
        XCTAssertEqual(snap.counters["c2.opk_missing"], 1)
        XCTAssertNil(snap.counters["c2.opk_failed_initiation"],
                     "legacy peer's OPK-missing path proceeds — must NOT record failed_initiation")
    }

    func test_telemetry_strict_records_bothEvents() throws {
        let k = makeFreshKeys()
        let metrics = CryptoHardeningMetrics()
        _ = try? X3DH.initiatorKeyAgreement(
            myIdentityKey: k.alice.ik,
            myEphemeralKey: k.alice.ek,
            theirIdentityKey: k.bob.ik.publicKey,
            theirSignedPreKey: k.bob.spk.publicKey,
            theirOneTimePreKey: nil,
            peerVersion: .v5_4_plus,
            policy: .bundledDefault,
            metrics: metrics
        )
        let snap = metrics.snapshot()
        XCTAssertEqual(snap.counters["c2.opk_missing"], 1,
                       "OPK-missing is always recorded, regardless of which branch fires")
        XCTAssertEqual(snap.counters["c2.opk_failed_initiation"], 1,
                       "strict peer's fail-closed branch records the dedicated event")
    }
}
