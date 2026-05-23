import XCTest
import CryptoKit
@testable import PeerDrop

final class X3DHProperties: XCTestCase {

    private func deterministicKey(seed: UInt64, salt: UInt8) -> Curve25519.KeyAgreement.PrivateKey {
        var bytes = Data(repeating: UInt8(seed & 0xFF), count: 32)
        bytes[0] ^= salt
        return DeterministicCrypto.curve25519AgreementKey(seed: bytes)
    }

    func test_property_legacyPeer_opkNil_alwaysProceeds() {
        PropertyTest.forAll(trials: 50, seed: 71) { rng in
            let s = rng.next()
            let aliceIK = deterministicKey(seed: s, salt: 0xA1)
            let aliceEK = deterministicKey(seed: s, salt: 0xA2)
            let bobIK = deterministicKey(seed: s, salt: 0xB1)
            let bobSPK = deterministicKey(seed: s, salt: 0xB2)
            do {
                let result = try X3DH.initiatorKeyAgreement(
                    myIdentityKey: aliceIK,
                    myEphemeralKey: aliceEK,
                    theirIdentityKey: bobIK.publicKey,
                    theirSignedPreKey: bobSPK.publicKey,
                    theirOneTimePreKey: nil,
                    peerVersion: .legacy,
                    policy: .bundledDefault,
                    metrics: nil
                )
                return !result.rootKey.withUnsafeBytes { Data($0) }.isEmpty
            } catch {
                return false
            }
        }
    }

    func test_property_v5_4Peer_opkNil_alwaysFailsClosed() {
        PropertyTest.forAll(trials: 50, seed: 72) { rng in
            let s = rng.next()
            let aliceIK = deterministicKey(seed: s, salt: 0xC1)
            let aliceEK = deterministicKey(seed: s, salt: 0xC2)
            let bobIK = deterministicKey(seed: s, salt: 0xD1)
            let bobSPK = deterministicKey(seed: s, salt: 0xD2)
            do {
                _ = try X3DH.initiatorKeyAgreement(
                    myIdentityKey: aliceIK,
                    myEphemeralKey: aliceEK,
                    theirIdentityKey: bobIK.publicKey,
                    theirSignedPreKey: bobSPK.publicKey,
                    theirOneTimePreKey: nil,
                    peerVersion: .v5_4_plus,
                    policy: .bundledDefault,
                    metrics: nil
                )
                return false  // Should have thrown.
            } catch X3DH.InitiationError.opkExhausted {
                return true   // Expected branch.
            } catch {
                return false  // Wrong error type.
            }
        }
    }

    func test_property_unknownPeer_opkNil_alwaysFailsClosed() {
        PropertyTest.forAll(trials: 50, seed: 73) { rng in
            let s = rng.next()
            let aliceIK = deterministicKey(seed: s, salt: 0xE1)
            let aliceEK = deterministicKey(seed: s, salt: 0xE2)
            let bobIK = deterministicKey(seed: s, salt: 0xF1)
            let bobSPK = deterministicKey(seed: s, salt: 0xF2)
            do {
                _ = try X3DH.initiatorKeyAgreement(
                    myIdentityKey: aliceIK,
                    myEphemeralKey: aliceEK,
                    theirIdentityKey: bobIK.publicKey,
                    theirSignedPreKey: bobSPK.publicKey,
                    theirOneTimePreKey: nil,
                    peerVersion: .unknown,
                    policy: .bundledDefault,
                    metrics: nil
                )
                return false
            } catch X3DH.InitiationError.opkExhausted {
                return true
            } catch {
                return false
            }
        }
    }

    func test_property_opkPresent_alwaysSucceeds_acrossPeerVersions() {
        PropertyTest.forAll(trials: 50, seed: 74) { rng in
            let s = rng.next()
            let aliceIK = deterministicKey(seed: s, salt: 0x11)
            let aliceEK = deterministicKey(seed: s, salt: 0x12)
            let bobIK = deterministicKey(seed: s, salt: 0x21)
            let bobSPK = deterministicKey(seed: s, salt: 0x22)
            let bobOPK = deterministicKey(seed: s, salt: 0x23)

            for version: PeerVersion in [.legacy, .v5_4_plus, .unknown] {
                do {
                    let result = try X3DH.initiatorKeyAgreement(
                        myIdentityKey: aliceIK,
                        myEphemeralKey: aliceEK,
                        theirIdentityKey: bobIK.publicKey,
                        theirSignedPreKey: bobSPK.publicKey,
                        theirOneTimePreKey: bobOPK.publicKey,
                        peerVersion: version,
                        policy: .bundledDefault,
                        metrics: nil
                    )
                    if result.rootKey.withUnsafeBytes({ Data($0) }).isEmpty {
                        return false  // Any version that produces empty key is wrong.
                    }
                } catch {
                    return false  // No version should throw when OPK is present.
                }
            }
            return true
        }
    }

    func test_property_strictMetric_opkMissing_alwaysRecorded() {
        // Across 50 strict-peer trials, c2.opk_missing should accumulate to 50.
        let metrics = CryptoHardeningMetrics()
        PropertyTest.forAll(trials: 50, seed: 75) { rng in
            let s = rng.next()
            let aliceIK = deterministicKey(seed: s, salt: 0x31)
            let aliceEK = deterministicKey(seed: s, salt: 0x32)
            let bobIK = deterministicKey(seed: s, salt: 0x41)
            let bobSPK = deterministicKey(seed: s, salt: 0x42)
            _ = try? X3DH.initiatorKeyAgreement(
                myIdentityKey: aliceIK,
                myEphemeralKey: aliceEK,
                theirIdentityKey: bobIK.publicKey,
                theirSignedPreKey: bobSPK.publicKey,
                theirOneTimePreKey: nil,
                peerVersion: .v5_4_plus,
                policy: .bundledDefault,
                metrics: metrics
            )
            return true
        }
        XCTAssertEqual(metrics.snapshot().counters["c2.opk_missing"], 50,
                       "every strict-peer-with-OPK-nil trial must record c2.opk_missing")
        XCTAssertEqual(metrics.snapshot().counters["c2.opk_failed_initiation"], 50,
                       "every strict-peer-with-OPK-nil trial must record c2.opk_failed_initiation")
    }
}
