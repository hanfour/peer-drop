import XCTest
import CryptoKit
@testable import PeerDrop

/// §8.4 Backward-compatibility 4-cell matrix.
///
/// These are pure unit tests, NOT UITests. Each cell asserts a named
/// compatibility property for a distinct pairing from the 2×2 matrix
/// of (initiator version) × (responder bundle version):
///
///   Cell 1 — v5.4 initiator ↔ v5.4 responder (baseline)
///   Cell 2 — v5.4 initiator ↔ legacy responder (timestamp-less bundle)
///   Cell 3 — legacy initiator ↔ v5.4 responder bundle (new fields ignored)
///   Cell 4 — Policy fetch failure → bundled defaults
@MainActor
final class V5_4_BackwardCompatTests: XCTestCase {

    // MARK: - Key material helper

    private struct KeyMaterial {
        // Alice (initiator)
        let aliceIdentityKA: Curve25519.KeyAgreement.PrivateKey
        let aliceEphemeralKA: Curve25519.KeyAgreement.PrivateKey

        // Bob (responder)
        let bobIdentityKA: Curve25519.KeyAgreement.PrivateKey
        let bobIdentitySigning: Curve25519.Signing.PrivateKey
        let bobSPK: Curve25519.KeyAgreement.PrivateKey
        let bobOPK: Curve25519.KeyAgreement.PrivateKey
    }

    /// Generate a fresh, independent set of X3DH key material.
    private func freshKeys() -> KeyMaterial {
        KeyMaterial(
            aliceIdentityKA:  Curve25519.KeyAgreement.PrivateKey(),
            aliceEphemeralKA: Curve25519.KeyAgreement.PrivateKey(),
            bobIdentityKA:    Curve25519.KeyAgreement.PrivateKey(),
            bobIdentitySigning: Curve25519.Signing.PrivateKey(),
            bobSPK:           Curve25519.KeyAgreement.PrivateKey(),
            bobOPK:           Curve25519.KeyAgreement.PrivateKey()
        )
    }

    /// Build a signed v5.4 timestamp for `spkPubkeyData` using `signingKey`.
    private func makeTimestampSignature(
        spkPubkeyData: Data,
        timestamp: UInt64,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        var payload = Data()
        payload.append(spkPubkeyData)
        var beTs = timestamp.bigEndian
        payload.append(Data(bytes: &beTs, count: 8))
        return try signingKey.signature(for: payload)
    }

    // MARK: - Cell 1: v5.4 ↔ v5.4 (baseline)

    /// Both sides are v5.4+. Bob emits a bundle with timestamp + signature populated.
    /// Expected: `verifyBundleFreshness` returns `.v5_4_plus`; X3DH with OPK present
    /// succeeds and derives a non-empty root key.
    func test_cell1_v5_4_to_v5_4_baseline() throws {
        let k = freshKeys()
        let spkPub = k.bobSPK.publicKey.rawRepresentation
        let timestamp = UInt64(Date().timeIntervalSince1970)
        let sig = try makeTimestampSignature(
            spkPubkeyData: spkPub,
            timestamp: timestamp,
            signingKey: k.bobIdentitySigning
        )

        // Freshness gate — expects .v5_4_plus.
        let detectedVersion = try X3DH.verifyBundleFreshness(
            signedPreKeyPublicKey: spkPub,
            signedPreKeyTimestamp: timestamp,
            signedPreKeyTimestampSignature: sig,
            peerSigningKey: k.bobIdentitySigning.publicKey,
            now: Date(),
            policy: .bundledDefault,
            metrics: nil
        )
        XCTAssertEqual(detectedVersion, .v5_4_plus,
                       "Cell 1: fresh v5.4 bundle should be detected as .v5_4_plus")

        // X3DH key agreement — OPK present, peerVersion .v5_4_plus.
        let result = try X3DH.initiatorKeyAgreement(
            myIdentityKey:      k.aliceIdentityKA,
            myEphemeralKey:     k.aliceEphemeralKA,
            theirIdentityKey:   k.bobIdentityKA.publicKey,
            theirSignedPreKey:  k.bobSPK.publicKey,
            theirOneTimePreKey: k.bobOPK.publicKey,
            peerVersion:        .v5_4_plus,
            policy:             .bundledDefault,
            metrics:            nil
        )
        let rootKeyBytes = result.rootKey.withUnsafeBytes { Data($0) }
        XCTAssertFalse(rootKeyBytes.isEmpty,
                       "Cell 1: X3DH should derive a non-empty root key")
        XCTAssertEqual(rootKeyBytes.count, 32,
                       "Cell 1: root key should be 32 bytes")
    }

    // MARK: - Cell 2: v5.4 initiator ↔ legacy responder

    /// Bob is a legacy v5.0–v5.3.x peer: bundle has no timestamp or signature.
    /// Expected: gate returns `.legacy`; X3DH without OPK proceeds (no fail-closed for
    /// legacy under bundledDefault); `.c2OpkMissing` metric recorded for `.legacy` peer.
    func test_cell2_v5_4_initiator_legacy_responder() throws {
        let k = freshKeys()

        // Legacy bundle has nil timestamp + nil signature.
        let metrics = CryptoHardeningMetrics()
        let detectedVersion = try X3DH.verifyBundleFreshness(
            signedPreKeyPublicKey: k.bobSPK.publicKey.rawRepresentation,
            signedPreKeyTimestamp: nil,
            signedPreKeyTimestampSignature: nil,
            peerSigningKey: k.bobIdentitySigning.publicKey,
            now: Date(),
            policy: .bundledDefault,
            metrics: metrics
        )
        XCTAssertEqual(detectedVersion, .legacy,
                       "Cell 2: nil-timestamp bundle should be detected as .legacy")
        XCTAssertEqual(metrics.snapshot().counters["c1.spk_timestamp_missing"], 1,
                       "Cell 2: c1.spk_timestamp_missing should be recorded for legacy peer")

        // X3DH without OPK (legacy peer ran out of OPKs).
        // bundledDefault.opkExhaustionBehavior(.legacy) == .proceedWithoutDH4 → no throw.
        let opkMetrics = CryptoHardeningMetrics()
        let result = try X3DH.initiatorKeyAgreement(
            myIdentityKey:      k.aliceIdentityKA,
            myEphemeralKey:     k.aliceEphemeralKA,
            theirIdentityKey:   k.bobIdentityKA.publicKey,
            theirSignedPreKey:  k.bobSPK.publicKey,
            theirOneTimePreKey: nil,
            peerVersion:        .legacy,
            policy:             .bundledDefault,
            metrics:            opkMetrics
        )
        let rootKeyBytes = result.rootKey.withUnsafeBytes { Data($0) }
        XCTAssertFalse(rootKeyBytes.isEmpty,
                       "Cell 2: legacy peer without OPK should still succeed (no fail-closed)")

        // Assert .c2OpkMissing was recorded with peerVersion .legacy.
        let snap = opkMetrics.snapshot()
        XCTAssertEqual(snap.counters["c2.opk_missing"], 1,
                       "Cell 2: c2.opk_missing should be recorded")
        let legacyKey = CryptoHardeningMetrics.Key(kind: "c2.opk_missing", peerVersion: "legacy")
        XCTAssertEqual(snap.keyedCounters[legacyKey], 1,
                       "Cell 2: c2.opk_missing should be recorded specifically for .legacy peer")
    }

    // MARK: - Cell 3: legacy initiator ↔ v5.4 responder bundle

    /// Bob (v5.4) emits a bundle with timestamp + signature. A legacy initiator
    /// only validates the legacy SPK signature and ignores the new timestamp fields.
    ///
    /// Expected:
    ///   - The classic SPK signature (`signedPreKey.signature`) still verifies against
    ///     Bob's signing public key (backward-compat: legacy clients can still validate).
    ///   - Calling `initiatorKeyAgreement` with `peerVersion: .legacy` (mimicking a
    ///     legacy initiator that doesn't run the freshness gate) succeeds and derives
    ///     a non-empty root key.
    func test_cell3_legacy_initiator_v5_4_responder_bundle() throws {
        let k = freshKeys()
        let spkPub = k.bobSPK.publicKey.rawRepresentation
        let timestamp = UInt64(Date().timeIntervalSince1970)
        // Classic legacy SPK signature: Ed25519(signingKey, spk_pubkey_bytes).
        let legacySpkSig = try k.bobIdentitySigning.signature(for: spkPub)
        let timestampSig = try makeTimestampSignature(
            spkPubkeyData: spkPub,
            timestamp: timestamp,
            signingKey: k.bobIdentitySigning
        )

        let bundle = PreKeyBundle(
            identityKey: k.bobIdentityKA.publicKey.rawRepresentation,
            signingKey:  k.bobIdentitySigning.publicKey.rawRepresentation,
            signedPreKey: PublicSignedPreKey(
                id: 1,
                publicKey: spkPub,
                signature: legacySpkSig,
                timestamp: Date()
            ),
            oneTimePreKeys: [PublicOneTimePreKey(id: 1, publicKey: k.bobOPK.publicKey.rawRepresentation)],
            signedPreKeyTimestamp: timestamp,
            signedPreKeyTimestampSignature: timestampSig
        )

        // Assert: the legacy SPK signature (the pre-v5.4 field) still verifies.
        // A legacy client performs exactly this check and nothing more.
        XCTAssertTrue(
            bundle.signedPreKey.verify(with: k.bobIdentitySigning.publicKey),
            "Cell 3: legacy SPK signature should verify against bob's signing public key"
        )

        // Assert: ignoring the new timestamp fields entirely, a legacy initiator's
        // X3DH path (peerVersion: .legacy, OPK present) derives a usable secret.
        let result = try X3DH.initiatorKeyAgreement(
            myIdentityKey:      k.aliceIdentityKA,
            myEphemeralKey:     k.aliceEphemeralKA,
            theirIdentityKey:   k.bobIdentityKA.publicKey,
            theirSignedPreKey:  k.bobSPK.publicKey,
            theirOneTimePreKey: k.bobOPK.publicKey,
            peerVersion:        .legacy,   // legacy initiator doesn't set .v5_4_plus
            policy:             .bundledDefault,
            metrics:            nil
        )
        let rootKeyBytes = result.rootKey.withUnsafeBytes { Data($0) }
        XCTAssertFalse(rootKeyBytes.isEmpty,
                       "Cell 3: legacy initiator reading v5.4 bundle should derive a non-empty root key")
        XCTAssertEqual(rootKeyBytes.count, 32,
                       "Cell 3: root key should be 32 bytes")
    }

    // MARK: - Cell 4: Policy fetch failure → bundled defaults

    /// `SecurityPolicyStore` has a URLSession injection seam (confirmed in
    /// `SecurityPolicyStore.swift`). We pass a session backed by `MockURLProtocol`
    /// with `responseError` set to a network error. After `fetchAndUpdate()`:
    ///   - `store.current` must equal `.bundledDefault`.
    ///   - The `policy.fetch_failure` metric must be recorded.
    ///
    /// This covers the spec §8.5 gate: "after a failed fetch, policy falls back
    /// to bundled defaults."
    func test_cell4_policy_fetch_failure_falls_back_to_bundled_default() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        MockURLProtocol.reset()
        MockURLProtocol.responseError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: nil
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let failingSession = URLSession(configuration: config)

        let metrics = CryptoHardeningMetrics()
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [],
            metrics: metrics,
            baseURL: URL(string: "https://peerdrop-signal.hanfourhuang.workers.dev")!,
            urlSession: failingSession,
            autoStartRefresh: false   // drive manually to avoid races
        )

        // Before fetch: already at bundled default (no cache, no network).
        XCTAssertEqual(store.current, .bundledDefault,
                       "Cell 4: store.current should start at .bundledDefault when no cache exists")

        // Run fetch — MockURLProtocol injects a network error.
        let succeeded = await store.fetchAndUpdate()
        XCTAssertFalse(succeeded, "Cell 4: fetchAndUpdate should return false on network error")

        // After failed fetch: must still be bundled default.
        XCTAssertEqual(store.current, .bundledDefault,
                       "Cell 4: store.current must remain .bundledDefault after a failed fetch")

        // Failure metric should be recorded.
        XCTAssertEqual(
            metrics.snapshot().counters["policy.fetch_failure"],
            1,
            "Cell 4: policy.fetch_failure metric must be recorded on network error"
        )
    }
}

