#!/usr/bin/env swift
// generate-test-vectors.swift
//
// Standalone Swift script that produces 20 frozen X3DH test vectors.
// Run: swift tools/generate-test-vectors.swift <output-dir>
//
// IMPORTANT: This script intentionally reimplements the X3DH math inline
// (rather than linking the app target) so that if PeerDrop/Security/Protocol/X3DH.swift
// ever drifts from this math, the X3DHVectorTests will catch the divergence.
//
// Math mirrors PeerDrop/Security/Protocol/X3DH.swift exactly:
//  - DH outputs extracted via no-op HKDF (empty salt, empty sharedInfo, 32-byte output)
//  - 3 DH outputs concatenated: DH1=DH(IK_A,SPK_B), DH2=DH(EK_A,IK_B), DH3=DH(EK_A,SPK_B)
//  - DH4=DH(EK_A,OPK_B) appended when OPK present (all 20 vectors include OPK)
//  - HKDF-Extract: PRK = HMAC-SHA256(salt=0x00*32, IKM=concatenated DH outputs)
//  - HKDF-Expand T(1): HMAC-SHA256(PRK, info || 0x01)          → rootKey
//  - HKDF-Expand T(2): HMAC-SHA256(PRK, T(1) || info || 0x02)  → chainKey
//  - info = "PeerDrop-X3DH-v1" (UTF-8)

import Foundation
import CryptoKit

// MARK: - Deterministic key derivation (inlined from DeterministicCrypto.swift)

func curve25519AgreementKey(seed: Data) -> Curve25519.KeyAgreement.PrivateKey {
    var attempt = seed
    for _ in 0..<8 {
        if let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: attempt) {
            return key
        }
        attempt = Data(SHA256.hash(data: attempt))
    }
    fatalError("Could not derive Curve25519 agreement key from seed after 8 retries")
}

// MARK: - Seed construction

/// Build a 32-byte seed for vector index `n` (1-based) and a field discriminator byte.
/// XOR-ing with the fieldByte ensures all 5 seeds per vector are distinct.
func makeSeed(vectorIndex n: Int, fieldByte: UInt8) -> Data {
    var bytes = Data(repeating: UInt8(n & 0xFF), count: 32)
    bytes[0] ^= fieldByte
    return bytes
}

// MARK: - X3DH math (inlined from X3DH.swift — must stay in sync with production)

/// Extract 32 raw bytes from a SharedSecret via a no-op HKDF
/// (empty salt, empty sharedInfo) — exactly as X3DH.deriveKeys(from:) does.
func extractSharedSecret(_ secret: SharedSecret) -> Data {
    let key = secret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: Data(),
        sharedInfo: Data(),
        outputByteCount: 32
    )
    return key.withUnsafeBytes { Data($0) }
}

struct X3DHResult {
    let rootKey: Data
    let chainKey: Data
}

func runX3DH(
    aliceIK: Curve25519.KeyAgreement.PrivateKey,
    aliceEK: Curve25519.KeyAgreement.PrivateKey,
    bobIK: Curve25519.KeyAgreement.PrivateKey,
    bobSPK: Curve25519.KeyAgreement.PrivateKey,
    bobOPK: Curve25519.KeyAgreement.PrivateKey?
) throws -> X3DHResult {
    // DH1 = DH(IK_A, SPK_B)
    let dh1 = try aliceIK.sharedSecretFromKeyAgreement(with: bobSPK.publicKey)
    // DH2 = DH(EK_A, IK_B)
    let dh2 = try aliceEK.sharedSecretFromKeyAgreement(with: bobIK.publicKey)
    // DH3 = DH(EK_A, SPK_B)
    let dh3 = try aliceEK.sharedSecretFromKeyAgreement(with: bobSPK.publicKey)

    var ikm = Data()
    ikm.append(extractSharedSecret(dh1))
    ikm.append(extractSharedSecret(dh2))
    ikm.append(extractSharedSecret(dh3))

    if let opk = bobOPK {
        // DH4 = DH(EK_A, OPK_B)
        let dh4 = try aliceEK.sharedSecretFromKeyAgreement(with: opk.publicKey)
        ikm.append(extractSharedSecret(dh4))
    }

    // HKDF-Extract: PRK = HMAC-SHA256(salt=0x00*32, IKM)
    let salt = Data(repeating: 0, count: 32)
    let info = Data("PeerDrop-X3DH-v1".utf8)

    let prk = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt))
    let prkKey = SymmetricKey(data: Data(prk))

    // HKDF-Expand T(1) = HMAC-SHA256(PRK, info || 0x01)
    var t1Input = info
    t1Input.append(0x01)
    let t1 = Data(HMAC<SHA256>.authenticationCode(for: t1Input, using: prkKey))

    // HKDF-Expand T(2) = HMAC-SHA256(PRK, T(1) || info || 0x02)
    var t2Input = t1
    t2Input.append(contentsOf: info)
    t2Input.append(0x02)
    let t2 = Data(HMAC<SHA256>.authenticationCode(for: t2Input, using: prkKey))

    return X3DHResult(rootKey: t1, chainKey: t2)
}

// MARK: - JSON output

func toHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func toBase64(_ data: Data) -> String {
    data.base64EncodedString()
}

struct VectorJSON: Encodable {
    let name: String
    let inputs: Inputs
    let expected: Expected

    struct Inputs: Encodable {
        let alice_ik_seed: String
        let bob_ik_seed: String
        let bob_spk_seed: String
        let bob_opk_seed: String
        let alice_ek_seed: String
    }
    struct Expected: Encodable {
        let root_key: String
        let chain_key: String
    }
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: swift tools/generate-test-vectors.swift <output-dir>\n", stderr)
    exit(1)
}

let outputDir = args[1]

// Ensure output directory exists
try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

for n in 1...20 {
    let aliceIKSeed = makeSeed(vectorIndex: n, fieldByte: 0xAA)
    let bobIKSeed   = makeSeed(vectorIndex: n, fieldByte: 0xBB)
    let bobSPKSeed  = makeSeed(vectorIndex: n, fieldByte: 0xCC)
    let bobOPKSeed  = makeSeed(vectorIndex: n, fieldByte: 0xDD)
    let aliceEKSeed = makeSeed(vectorIndex: n, fieldByte: 0xEE)

    let aliceIK = curve25519AgreementKey(seed: aliceIKSeed)
    let bobIK   = curve25519AgreementKey(seed: bobIKSeed)
    let bobSPK  = curve25519AgreementKey(seed: bobSPKSeed)
    let bobOPK  = curve25519AgreementKey(seed: bobOPKSeed)
    let aliceEK = curve25519AgreementKey(seed: aliceEKSeed)

    let result = try runX3DH(
        aliceIK: aliceIK,
        aliceEK: aliceEK,
        bobIK: bobIK,
        bobSPK: bobSPK,
        bobOPK: bobOPK
    )

    let name = String(format: "x3dh_vec_%03d", n)
    let vector = VectorJSON(
        name: name,
        inputs: VectorJSON.Inputs(
            alice_ik_seed: toHex(aliceIKSeed),
            bob_ik_seed:   toHex(bobIKSeed),
            bob_spk_seed:  toHex(bobSPKSeed),
            bob_opk_seed:  toHex(bobOPKSeed),
            alice_ek_seed: toHex(aliceEKSeed)
        ),
        expected: VectorJSON.Expected(
            root_key:  toBase64(result.rootKey),
            chain_key: toBase64(result.chainKey)
        )
    )

    let jsonData = try encoder.encode(vector)
    let filename = String(format: "vec-%03d.json", n)
    let outPath = (outputDir as NSString).appendingPathComponent(filename)
    try jsonData.write(to: URL(fileURLWithPath: outPath))
    print("Generated \(filename)")
}

print("Done — 20 vectors written to \(outputDir)")
