import XCTest
import CryptoKit
import PeerDropSecurity
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

    // MARK: - C1: SPK Timestamp verification

    /// Helper: build a PreKeyBundle with caller-controlled timestamp / signature state.
    /// Returns (bundle, signingPubKey) so the test can also pass the verifying key.
    /// Uses a random Ed25519 signing key (reliable) while the rng seed governs
    /// reproducible choices for SPK key material and timestamps.
    private func makeC1TestBundle(
        rng: inout PropertyTest.SeededRNG,
        includeTimestamp: Bool,
        includeSignature: Bool,
        timestamp: UInt64? = nil,
        tamperSignature: Bool = false
    ) -> (bundle: PreKeyBundle, signingKey: Curve25519.Signing.PublicKey) {
        let s = rng.next()
        // SPK key material derived deterministically from seed.
        let spkKA = deterministicKey(seed: s, salt: 0xC2)
        let spkPubData = spkKA.publicKey.rawRepresentation

        // Use a fresh random signing key — deterministic Ed25519 derivation from
        // SHA-256 is unreliable; random is simpler and sufficient for property tests.
        let signingPriv = Curve25519.Signing.PrivateKey()
        let legacySpkSig = (try? signingPriv.signature(for: spkPubData)) ?? Data()

        let ts = timestamp ?? UInt64(Date().timeIntervalSince1970)
        var tsSig: Data? = nil
        if includeSignature {
            var payload = Data()
            payload.append(spkPubData)
            var be = ts.bigEndian
            payload.append(Data(bytes: &be, count: 8))
            var sig = (try? signingPriv.signature(for: payload)) ?? Data()
            if tamperSignature && !sig.isEmpty {
                sig[sig.index(before: sig.endIndex)] ^= 0xFF
            }
            tsSig = sig
        }

        let identityKA = deterministicKey(seed: s, salt: 0xC0)
        let bundle = PreKeyBundle(
            identityKey: identityKA.publicKey.rawRepresentation,
            signingKey: signingPriv.publicKey.rawRepresentation,
            signedPreKey: PublicSignedPreKey(
                id: 1,
                publicKey: spkPubData,
                signature: legacySpkSig,
                timestamp: Date()
            ),
            oneTimePreKeys: [],
            signedPreKeyTimestamp: includeTimestamp ? ts : nil,
            signedPreKeyTimestampSignature: tsSig
        )
        return (bundle, signingPriv.publicKey)
    }

    func test_property_c1_legacy_both_nil_always_returnsLegacy() {
        PropertyTest.forAll(trials: 50, seed: 81) { rng in
            let (bundle, signingKey) = self.makeC1TestBundle(
                rng: &rng, includeTimestamp: false, includeSignature: false
            )
            do {
                let v = try X3DH.verifyBundleFreshness(
                    signedPreKeyPublicKey: bundle.signedPreKey.publicKey,
                    signedPreKeyTimestamp: bundle.signedPreKeyTimestamp,
                    signedPreKeyTimestampSignature: bundle.signedPreKeyTimestampSignature,
                    peerSigningKey: signingKey,
                    now: Date(),
                    policy: .bundledDefault,
                    metrics: nil
                )
                return v == .legacy
            } catch {
                return false
            }
        }
    }

    func test_property_c1_malformed_only_timestamp_always_throws() {
        PropertyTest.forAll(trials: 50, seed: 82) { rng in
            let (bundle, signingKey) = self.makeC1TestBundle(
                rng: &rng, includeTimestamp: true, includeSignature: false
            )
            do {
                _ = try X3DH.verifyBundleFreshness(
                    signedPreKeyPublicKey: bundle.signedPreKey.publicKey,
                    signedPreKeyTimestamp: bundle.signedPreKeyTimestamp,
                    signedPreKeyTimestampSignature: bundle.signedPreKeyTimestampSignature,
                    peerSigningKey: signingKey,
                    now: Date(), policy: .bundledDefault, metrics: nil
                )
                return false
            } catch X3DH.InitiationError.timestampMalformed {
                return true
            } catch {
                return false
            }
        }
    }

    func test_property_c1_malformed_only_signature_always_throws() {
        PropertyTest.forAll(trials: 50, seed: 83) { rng in
            let (bundle, signingKey) = self.makeC1TestBundle(
                rng: &rng, includeTimestamp: false, includeSignature: true
            )
            do {
                _ = try X3DH.verifyBundleFreshness(
                    signedPreKeyPublicKey: bundle.signedPreKey.publicKey,
                    signedPreKeyTimestamp: bundle.signedPreKeyTimestamp,
                    signedPreKeyTimestampSignature: bundle.signedPreKeyTimestampSignature,
                    peerSigningKey: signingKey,
                    now: Date(), policy: .bundledDefault, metrics: nil
                )
                return false
            } catch X3DH.InitiationError.timestampMalformed {
                return true
            } catch {
                return false
            }
        }
    }

    func test_property_c1_invalidSignature_always_throws() {
        PropertyTest.forAll(trials: 50, seed: 84) { rng in
            let (bundle, signingKey) = self.makeC1TestBundle(
                rng: &rng, includeTimestamp: true, includeSignature: true, tamperSignature: true
            )
            do {
                _ = try X3DH.verifyBundleFreshness(
                    signedPreKeyPublicKey: bundle.signedPreKey.publicKey,
                    signedPreKeyTimestamp: bundle.signedPreKeyTimestamp,
                    signedPreKeyTimestampSignature: bundle.signedPreKeyTimestampSignature,
                    peerSigningKey: signingKey,
                    now: Date(), policy: .bundledDefault, metrics: nil
                )
                return false
            } catch X3DH.InitiationError.timestampSignatureInvalid {
                return true
            } catch {
                return false
            }
        }
    }

    func test_property_c1_warnMode_tooOld_returns_v5_4_plus() {
        PropertyTest.forAll(trials: 50, seed: 85) { rng in
            // Pick a stale age: 22..199 days (always > 21-day default threshold)
            let staleAgeSeconds = UInt64(22 + Int(rng.next() % 178)) * 86400
            let now = UInt64(Date().timeIntervalSince1970)
            let oldTs = now > staleAgeSeconds ? now - staleAgeSeconds : 0
            let (bundle, signingKey) = self.makeC1TestBundle(
                rng: &rng, includeTimestamp: true, includeSignature: true, timestamp: oldTs
            )
            do {
                let v = try X3DH.verifyBundleFreshness(
                    signedPreKeyPublicKey: bundle.signedPreKey.publicKey,
                    signedPreKeyTimestamp: bundle.signedPreKeyTimestamp,
                    signedPreKeyTimestampSignature: bundle.signedPreKeyTimestampSignature,
                    peerSigningKey: signingKey,
                    now: Date(), policy: .bundledDefault, metrics: nil
                )
                return v == .v5_4_plus
            } catch {
                return false
            }
        }
    }

    func test_property_c1_rejectMode_tooOld_always_throws() {
        let strictPolicy = SecurityPolicy(
            spkMaxAgeDays: 21,
            spkExpirationBehavior: .reject,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 5,
            opkRetryIntervalSeconds: 60,
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90
        )
        PropertyTest.forAll(trials: 50, seed: 86) { rng in
            let staleAgeSeconds = UInt64(22 + Int(rng.next() % 178)) * 86400
            let now = UInt64(Date().timeIntervalSince1970)
            let oldTs = now > staleAgeSeconds ? now - staleAgeSeconds : 0
            let (bundle, signingKey) = self.makeC1TestBundle(
                rng: &rng, includeTimestamp: true, includeSignature: true, timestamp: oldTs
            )
            do {
                _ = try X3DH.verifyBundleFreshness(
                    signedPreKeyPublicKey: bundle.signedPreKey.publicKey,
                    signedPreKeyTimestamp: bundle.signedPreKeyTimestamp,
                    signedPreKeyTimestampSignature: bundle.signedPreKeyTimestampSignature,
                    peerSigningKey: signingKey,
                    now: Date(), policy: strictPolicy, metrics: nil
                )
                return false
            } catch X3DH.InitiationError.timestampTooOld {
                return true
            } catch {
                return false
            }
        }
    }

    func test_property_c1_fresh_valid_always_returns_v5_4_plus() {
        PropertyTest.forAll(trials: 50, seed: 87) { rng in
            // Pick an age strictly inside the 21-day window: 0..19 days.
            let freshAgeSeconds = UInt64(Int(rng.next() % 20)) * 86400
            let now = UInt64(Date().timeIntervalSince1970)
            let recentTs = now > freshAgeSeconds ? now - freshAgeSeconds : now
            let (bundle, signingKey) = self.makeC1TestBundle(
                rng: &rng, includeTimestamp: true, includeSignature: true, timestamp: recentTs
            )
            do {
                let v = try X3DH.verifyBundleFreshness(
                    signedPreKeyPublicKey: bundle.signedPreKey.publicKey,
                    signedPreKeyTimestamp: bundle.signedPreKeyTimestamp,
                    signedPreKeyTimestampSignature: bundle.signedPreKeyTimestampSignature,
                    peerSigningKey: signingKey,
                    now: Date(), policy: .bundledDefault, metrics: nil
                )
                return v == .v5_4_plus
            } catch {
                return false
            }
        }
    }
}
