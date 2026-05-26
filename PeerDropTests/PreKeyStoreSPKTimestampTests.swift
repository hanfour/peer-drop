import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDrop

final class PreKeyStoreSPKTimestampTests: XCTestCase {

    func test_emittedBundle_carriesTimestamp_andSignature() throws {
        let storageKey = "test-c1-\(UUID().uuidString)"
        let store = PreKeyStore(storageKey: storageKey)
        defer { store.deleteAll() }
        let bundle = store.generatePreKeyBundle()

        XCTAssertNotNil(bundle.signedPreKeyTimestamp,
                        "v5.4+ bundles must always include the timestamp")
        XCTAssertNotNil(bundle.signedPreKeyTimestampSignature,
                        "v5.4+ bundles must always include the timestamp signature")

        // Timestamp should be very recent.
        let now = UInt64(Date().timeIntervalSince1970)
        let ts = try XCTUnwrap(bundle.signedPreKeyTimestamp)
        XCTAssertLessThanOrEqual(now - ts, 60, "timestamp must be within 60s of now")

        // Verify the signature locally using the bundle's signing public key.
        // Payload = SPK_pubkey || timestamp_BE_8B (per spec §4.1).
        let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: bundle.signingKey)
        let spkPubkey = bundle.signedPreKey.publicKey
        let sig = try XCTUnwrap(bundle.signedPreKeyTimestampSignature)
        var payload = Data()
        payload.append(spkPubkey)
        payload.append(uint64BE(ts))
        XCTAssertTrue(
            signingKey.isValidSignature(sig, for: payload),
            "timestamp signature must verify against (SPK_pubkey || timestamp_BE_8B)"
        )
    }

    func test_legacy_spk_signature_still_present() throws {
        // Backward compat: the existing SPK signature (over SPK_pubkey alone) is
        // untouched. v5.0–v5.3 clients keep verifying it without knowing about
        // the new timestamp fields.
        let store = PreKeyStore(storageKey: "test-c1-legacy-\(UUID().uuidString)")
        defer { store.deleteAll() }
        let bundle = store.generatePreKeyBundle()
        XCTAssertFalse(
            bundle.signedPreKey.signature.isEmpty,
            "legacy SPK signature field must still be populated"
        )

        // Verify the legacy signature still verifies correctly against SPK_pubkey alone.
        let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: bundle.signingKey)
        XCTAssertTrue(
            signingKey.isValidSignature(bundle.signedPreKey.signature, for: bundle.signedPreKey.publicKey),
            "legacy SPK signature must still verify against SPK pubkey alone"
        )
    }

    // MARK: - Helper

    /// 8-byte big-endian encoding of a UInt64.
    private func uint64BE(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 8)
    }
}
