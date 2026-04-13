import Foundation
import CryptoKit

/// X3DH (Extended Triple Diffie-Hellman) key agreement protocol.
/// Establishes a shared secret between two parties, even when one is offline.
/// Reference: https://signal.org/docs/specifications/x3dh/
enum X3DH {

    struct KeyAgreementResult {
        let rootKey: SymmetricKey       // For initializing the Double Ratchet root chain
        let chainKey: SymmetricKey      // For initializing the Double Ratchet sending chain
    }

    /// Alice (initiator) computes the shared secret using Bob's pre-key bundle.
    static func initiatorKeyAgreement(
        myIdentityKey: Curve25519.KeyAgreement.PrivateKey,      // IK_A
        myEphemeralKey: Curve25519.KeyAgreement.PrivateKey,      // EK_A
        theirIdentityKey: Curve25519.KeyAgreement.PublicKey,     // IK_B
        theirSignedPreKey: Curve25519.KeyAgreement.PublicKey,    // SPK_B
        theirOneTimePreKey: Curve25519.KeyAgreement.PublicKey?   // OPK_B (optional)
    ) throws -> KeyAgreementResult {
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
    static func responderKeyAgreement(
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
