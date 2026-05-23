import XCTest
import CryptoKit
@testable import PeerDrop

final class X3DHSPKTimestampTests: XCTestCase {

    // MARK: - Helpers

    private struct TestBundle {
        let bundle: PreKeyBundle
        let identitySigningKey: Curve25519.Signing.PrivateKey
    }

    /// Build a PreKeyBundle whose timestamp is freshly signed by a known
    /// Ed25519 key. Caller controls timestamp + whether to include
    /// the timestamp / signature fields.
    private func makeBundle(
        includeTimestamp: Bool,
        includeSignature: Bool,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970),
        tamperSignature: Bool = false
    ) -> TestBundle {
        let identityKA = Curve25519.KeyAgreement.PrivateKey()
        let identitySigning = Curve25519.Signing.PrivateKey()
        let spk = Curve25519.KeyAgreement.PrivateKey()
        let spkPubkeyData = spk.publicKey.rawRepresentation
        // Build a legacy-shape SignedPreKey signature for `bundle.signedPreKey.signature`.
        let legacySpkSig = try! identitySigning.signature(for: spkPubkeyData)

        // Build the timestamp signature if requested.
        var timestampSig: Data? = nil
        if includeSignature {
            var payload = Data()
            payload.append(spkPubkeyData)
            var be = timestamp.bigEndian
            payload.append(Data(bytes: &be, count: 8))
            var sig = try! identitySigning.signature(for: payload)
            if tamperSignature {
                // Flip the last byte.
                sig[sig.index(before: sig.endIndex)] ^= 0xFF
            }
            timestampSig = sig
        }

        let bundle = PreKeyBundle(
            identityKey: identityKA.publicKey.rawRepresentation,
            signingKey: identitySigning.publicKey.rawRepresentation,
            signedPreKey: PublicSignedPreKey(
                id: 1,
                publicKey: spkPubkeyData,
                signature: legacySpkSig,
                timestamp: Date()
            ),
            oneTimePreKeys: [],
            signedPreKeyTimestamp: includeTimestamp ? timestamp : nil,
            signedPreKeyTimestampSignature: timestampSig
        )
        return TestBundle(bundle: bundle, identitySigningKey: identitySigning)
    }

    // MARK: - Branch 1: legacy peer (both fields nil)

    func test_legacy_bundle_proceeds_asLegacyPeer() throws {
        let tb = makeBundle(includeTimestamp: false, includeSignature: false)
        let metrics = CryptoHardeningMetrics()
        let result = try X3DH.verifyBundleFreshness(
            bundle: tb.bundle,
            peerSigningKey: tb.identitySigningKey.publicKey,
            now: Date(),
            policy: .bundledDefault,
            metrics: metrics
        )
        XCTAssertEqual(result, .legacy)
        XCTAssertEqual(metrics.snapshot().counters["c1.spk_timestamp_missing"], 1)
    }

    // MARK: - Branch 2: malformed (exactly one field present)

    func test_only_timestamp_present_throws_malformed() {
        let tb = makeBundle(includeTimestamp: true, includeSignature: false)
        let metrics = CryptoHardeningMetrics()
        XCTAssertThrowsError(try X3DH.verifyBundleFreshness(
            bundle: tb.bundle,
            peerSigningKey: tb.identitySigningKey.publicKey,
            now: Date(),
            policy: .bundledDefault,
            metrics: metrics
        )) { error in
            guard case X3DH.InitiationError.timestampMalformed = error else {
                return XCTFail("expected .timestampMalformed, got \(error)")
            }
        }
        XCTAssertEqual(metrics.snapshot().counters["c1.spk_timestamp_malformed"], 1)
    }

    func test_only_signature_present_throws_malformed() {
        let tb = makeBundle(includeTimestamp: false, includeSignature: true)
        XCTAssertThrowsError(try X3DH.verifyBundleFreshness(
            bundle: tb.bundle,
            peerSigningKey: tb.identitySigningKey.publicKey,
            now: Date(),
            policy: .bundledDefault,
            metrics: nil
        )) { error in
            guard case X3DH.InitiationError.timestampMalformed = error else {
                return XCTFail("expected .timestampMalformed, got \(error)")
            }
        }
    }

    // MARK: - Branch 3: invalid signature

    func test_invalid_signature_throws_timestampSignatureInvalid() {
        let tb = makeBundle(includeTimestamp: true, includeSignature: true, tamperSignature: true)
        let metrics = CryptoHardeningMetrics()
        XCTAssertThrowsError(try X3DH.verifyBundleFreshness(
            bundle: tb.bundle,
            peerSigningKey: tb.identitySigningKey.publicKey,
            now: Date(),
            policy: .bundledDefault,
            metrics: metrics
        )) { error in
            guard case X3DH.InitiationError.timestampSignatureInvalid = error else {
                return XCTFail("expected .timestampSignatureInvalid, got \(error)")
            }
        }
        XCTAssertEqual(metrics.snapshot().counters["c1.spk_timestamp_invalid_signature"], 1)
    }

    // MARK: - Branch 4a: too old, .warn → proceed

    func test_too_old_in_warn_mode_proceeds_with_metric() throws {
        // Build with timestamp = now - 30 days (older than the 21-day default threshold)
        let oldTs = UInt64(Date().timeIntervalSince1970) - (30 * 86400)
        let tb = makeBundle(includeTimestamp: true, includeSignature: true, timestamp: oldTs)
        let metrics = CryptoHardeningMetrics()
        // bundledDefault has spkExpirationBehavior = .warn
        let result = try X3DH.verifyBundleFreshness(
            bundle: tb.bundle,
            peerSigningKey: tb.identitySigningKey.publicKey,
            now: Date(),
            policy: .bundledDefault,
            metrics: metrics
        )
        XCTAssertEqual(result, .v5_4_plus)
        XCTAssertEqual(metrics.snapshot().counters["c1.spk_timestamp_too_old"], 1)
    }

    // MARK: - Branch 4b: too old, .reject → throw

    func test_too_old_in_reject_mode_throws() {
        let oldTs = UInt64(Date().timeIntervalSince1970) - (30 * 86400)
        let tb = makeBundle(includeTimestamp: true, includeSignature: true, timestamp: oldTs)
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
        XCTAssertThrowsError(try X3DH.verifyBundleFreshness(
            bundle: tb.bundle,
            peerSigningKey: tb.identitySigningKey.publicKey,
            now: Date(),
            policy: strictPolicy,
            metrics: nil
        )) { error in
            guard case X3DH.InitiationError.timestampTooOld = error else {
                return XCTFail("expected .timestampTooOld, got \(error)")
            }
        }
    }

    // MARK: - Branch 5: fresh valid → proceed normally

    func test_fresh_valid_proceeds_asV5_4Plus() throws {
        let tb = makeBundle(includeTimestamp: true, includeSignature: true)  // timestamp = now
        let metrics = CryptoHardeningMetrics()
        let result = try X3DH.verifyBundleFreshness(
            bundle: tb.bundle,
            peerSigningKey: tb.identitySigningKey.publicKey,
            now: Date(),
            policy: .bundledDefault,
            metrics: metrics
        )
        XCTAssertEqual(result, .v5_4_plus)
        XCTAssertEqual(metrics.snapshot().counters["c1.spk_timestamp_valid"], 1)
    }
}
