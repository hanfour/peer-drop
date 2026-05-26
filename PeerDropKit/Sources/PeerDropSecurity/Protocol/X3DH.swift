import Foundation
import CryptoKit

/// X3DH (Extended Triple Diffie-Hellman) key agreement protocol.
/// Establishes a shared secret between two parties, even when one is offline.
/// Reference: https://signal.org/docs/specifications/x3dh/
public enum X3DH {

    public struct KeyAgreementResult {
        public let rootKey: SymmetricKey       // For initializing the Double Ratchet root chain
        public let chainKey: SymmetricKey      // For initializing the Double Ratchet sending chain
    }

    /// Alice (initiator) computes the shared secret using Bob's pre-key bundle.
    ///
    /// - Parameters:
    ///   - peerVersion: Detected version of the remote peer. Defaults to `.unknown` so
    ///     existing callers compile unchanged; `.unknown` routes to the strict (fail-closed)
    ///     policy for nil OPK, which is the intended production default.
    ///   - policy: Active `SecurityPolicy`. Defaults to `.bundledDefault`.
    ///   - metrics: Optional telemetry sink. Records C2 events when OPK is absent.
    public static func initiatorKeyAgreement(
        myIdentityKey: Curve25519.KeyAgreement.PrivateKey,      // IK_A
        myEphemeralKey: Curve25519.KeyAgreement.PrivateKey,      // EK_A
        theirIdentityKey: Curve25519.KeyAgreement.PublicKey,     // IK_B
        theirSignedPreKey: Curve25519.KeyAgreement.PublicKey,    // SPK_B
        theirOneTimePreKey: Curve25519.KeyAgreement.PublicKey?,  // OPK_B (optional)
        peerVersion: PeerVersion = .unknown,
        policy: SecurityPolicy = .bundledDefault,
        metrics: CryptoHardeningMetrics? = nil
    ) throws -> KeyAgreementResult {
        // Fail-closed gate (C2): if OPK is missing, consult policy for this peer version.
        if theirOneTimePreKey == nil {
            metrics?.record(.c2OpkMissing, peerVersion: peerVersion)
            let behavior = policy.opkExhaustionBehavior(peerVersion)
            if behavior == .failClosed {
                metrics?.record(.c2OpkFailedInitiation, peerVersion: peerVersion)
                throw InitiationError.opkExhausted
            }
            // .proceedWithoutDH4: fall through, skip DH4 below.
        }

        // DH1 = DH(IK_A, SPK_B)
        let dh1 = try myIdentityKey.sharedSecretFromKeyAgreement(with: theirSignedPreKey)
        // DH2 = DH(EK_A, IK_B)
        let dh2 = try myEphemeralKey.sharedSecretFromKeyAgreement(with: theirIdentityKey)
        // DH3 = DH(EK_A, SPK_B)
        let dh3 = try myEphemeralKey.sharedSecretFromKeyAgreement(with: theirSignedPreKey)

        var dhResults = [dh1, dh2, dh3]

        // DH4 = DH(EK_A, OPK_B) — only if one-time pre-key was available
        if let opk = theirOneTimePreKey {
            let dh4 = try myEphemeralKey.sharedSecretFromKeyAgreement(with: opk)
            dhResults.append(dh4)
        }

        return deriveKeys(from: dhResults)
    }

    /// Bob (responder) computes the shared secret using Alice's initial message.
    public static func responderKeyAgreement(
        myIdentityKey: Curve25519.KeyAgreement.PrivateKey,       // IK_B
        mySignedPreKey: Curve25519.KeyAgreement.PrivateKey,      // SPK_B
        myOneTimePreKey: Curve25519.KeyAgreement.PrivateKey?,    // OPK_B (optional)
        theirIdentityKey: Curve25519.KeyAgreement.PublicKey,     // IK_A
        theirEphemeralKey: Curve25519.KeyAgreement.PublicKey      // EK_A
    ) throws -> KeyAgreementResult {
        // DH1 = DH(SPK_B, IK_A) — same shared secret as DH(IK_A, SPK_B)
        let dh1 = try mySignedPreKey.sharedSecretFromKeyAgreement(with: theirIdentityKey)
        // DH2 = DH(IK_B, EK_A)
        let dh2 = try myIdentityKey.sharedSecretFromKeyAgreement(with: theirEphemeralKey)
        // DH3 = DH(SPK_B, EK_A)
        let dh3 = try mySignedPreKey.sharedSecretFromKeyAgreement(with: theirEphemeralKey)

        var dhResults = [dh1, dh2, dh3]

        if let opk = myOneTimePreKey {
            let dh4 = try opk.sharedSecretFromKeyAgreement(with: theirEphemeralKey)
            dhResults.append(dh4)
        }

        return deriveKeys(from: dhResults)
    }

    // MARK: - Private

    private static func deriveKeys(from secrets: [SharedSecret]) -> KeyAgreementResult {
        // ⚠️ NON-STANDARD: CryptoKit SharedSecret does not expose raw bytes.
        // We extract each DH output via a no-op HKDF (empty salt/info), then feed
        // the concatenation into a second HKDF. This produces a deterministic result
        // but is NOT wire-compatible with libsignal or other Signal Protocol implementations.
        // This is acceptable because PeerDrop only communicates with itself.
        var ikm = Data()
        for secret in secrets {
            let key = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(),
                sharedInfo: Data(),
                outputByteCount: 32
            )
            key.withUnsafeBytes { ikm.append(contentsOf: $0) }
        }

        // Derive root key and chain key using HKDF
        let salt = Data(repeating: 0, count: 32) // Zero salt per Signal spec
        let info = "PeerDrop-X3DH-v1".data(using: .utf8)!

        // HKDF-Extract: PRK = HMAC(salt, IKM)
        let prk = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt))
        let prkKey = SymmetricKey(data: Data(prk))

        // HKDF-Expand: T(1) = HMAC(PRK, info || 0x01)
        var t1Input = info
        t1Input.append(0x01)
        let t1 = Data(HMAC<SHA256>.authenticationCode(for: t1Input, using: prkKey))

        // T(2) = HMAC(PRK, T(1) || info || 0x02)
        var t2Input = t1
        t2Input.append(contentsOf: info)
        t2Input.append(0x02)
        let t2 = Data(HMAC<SHA256>.authenticationCode(for: t2Input, using: prkKey))

        return KeyAgreementResult(
            rootKey: SymmetricKey(data: t1),
            chainKey: SymmetricKey(data: t2)
        )
    }
}

extension X3DH {
    /// Errors thrown by the initiator side of X3DH.
    public enum InitiationError: Error, Equatable {
        /// Responder's OPK list is empty AND `policy.opkExhaustionBehavior`
        /// for this peer's version returned `.failClosed`. The caller should
        /// enqueue the message into `OutboundRetryQueue` for later retry.
        case opkExhausted

        /// Bundle has exactly one of (timestamp, signature) present — looks
        /// like wire tampering or a partially-upgraded sender.
        case timestampMalformed

        /// Bundle has both timestamp + signature fields but the signature
        /// does not verify against the peer's identity signing key using the
        /// payload `SPK_pubkey || timestamp_BE_8B`.
        case timestampSignatureInvalid

        /// Bundle is validly signed but the timestamp is older than
        /// `policy.spkMaxAgeDays` AND `policy.spkExpirationBehavior == .reject`.
        case timestampTooOld
    }
}

extension X3DH {

    /// Verify the freshness gate on a peer's PreKeyBundle (C1).
    ///
    /// Per spec §4.1 — 5 decision branches based on which of the optional
    /// timestamp fields are present, whether the signature verifies, and
    /// whether the timestamp is within `policy.spkMaxAgeDays`:
    ///
    /// 1. Both fields absent → return `.legacy` (legacy peer).
    /// 2. Exactly one field present → throw `.timestampMalformed`.
    /// 3. Both present, signature invalid → throw `.timestampSignatureInvalid`.
    /// 4a. Both present, valid, too old, policy `.warn` → return `.v5_4_plus`.
    /// 4b. Both present, valid, too old, policy `.reject` → throw `.timestampTooOld`.
    /// 5. Both present, valid, fresh → return `.v5_4_plus`.
    ///
    /// The signature payload is `SPK_pubkey_bytes || timestamp_BE_8_bytes`,
    /// matching the signing layout used by Task 6.2's `PreKeyStore`.
    ///
    /// Returns the detected `PeerVersion` so the caller can pass it through
    /// to `initiatorKeyAgreement` (PR7 wires the actual call sites).
    public static func verifyBundleFreshness(
        signedPreKeyPublicKey: Data,
        signedPreKeyTimestamp: UInt64?,
        signedPreKeyTimestampSignature: Data?,
        peerSigningKey: Curve25519.Signing.PublicKey,
        now: Date,
        policy: SecurityPolicy,
        metrics: CryptoHardeningMetrics?
    ) throws -> PeerVersion {

        let ts = signedPreKeyTimestamp
        let sig = signedPreKeyTimestampSignature

        // Branch 1: both absent → legacy peer.
        if ts == nil && sig == nil {
            metrics?.record(.c1SpkTimestampMissing, peerVersion: .legacy)
            return .legacy
        }

        // Branch 2: exactly one present → malformed.
        guard let timestamp = ts, let signature = sig else {
            metrics?.record(.c1SpkTimestampMalformed, peerVersion: .v5_4_plus)
            throw InitiationError.timestampMalformed
        }

        // Reconstruct the signed payload: SPK_pubkey || timestamp_BE_8B.
        var payload = Data()
        payload.append(signedPreKeyPublicKey)
        var beTs = timestamp.bigEndian
        payload.append(Data(bytes: &beTs, count: 8))

        // Branch 3: signature invalid → reject.
        guard peerSigningKey.isValidSignature(signature, for: payload) else {
            metrics?.record(.c1SpkTimestampInvalidSignature, peerVersion: .v5_4_plus)
            throw InitiationError.timestampSignatureInvalid
        }

        // Compute age in seconds, with clock-skew tolerance for slightly-future
        // timestamps. A malicious responder cannot pin a far-future timestamp
        // to evade the freshness check forever — beyond the tolerance we treat
        // it as expired so the rotation-required behavior still applies.
        let clockSkewToleranceSeconds: UInt64 = 60
        let nowTs = UInt64(now.timeIntervalSince1970)
        let ageSeconds: Int64
        if nowTs >= timestamp {
            ageSeconds = Int64(nowTs - timestamp)
        } else {
            // Future-dated: tolerate small skew (clocks drift); reject anything beyond.
            let skewSeconds = timestamp - nowTs
            if skewSeconds > clockSkewToleranceSeconds {
                metrics?.record(.c1SpkTimestampTooOld, peerVersion: .v5_4_plus)
                switch policy.spkExpirationBehavior {
                case .warn:
                    return .v5_4_plus
                case .reject:
                    throw InitiationError.timestampTooOld
                }
            }
            ageSeconds = 0   // within skew tolerance — treat as fresh
        }
        let maxAgeSeconds = Int64(policy.spkMaxAgeDays) * 86400

        if ageSeconds > maxAgeSeconds {
            // Too old: record telemetry + branch on policy.
            metrics?.record(.c1SpkTimestampTooOld, peerVersion: .v5_4_plus)
            switch policy.spkExpirationBehavior {
            case .warn:
                return .v5_4_plus       // Branch 4a: warn and proceed.
            case .reject:
                throw InitiationError.timestampTooOld   // Branch 4b: hard reject.
            }
        }

        // Branch 5: fresh + valid.
        metrics?.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        return .v5_4_plus
    }
}
