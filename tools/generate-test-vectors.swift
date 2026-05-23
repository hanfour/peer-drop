#!/usr/bin/env swift
// generate-test-vectors.swift
//
// Standalone Swift script that produces:
//   - 20 frozen X3DH test vectors    → written to <output-dir>/x3dh/
//   - 30 frozen Double Ratchet vectors → written to <output-dir>/ratchet/
//
// Run: swift tools/generate-test-vectors.swift <output-dir>
//
// IMPORTANT: This script intentionally reimplements the X3DH and Double
// Ratchet math inline (rather than linking the app target) so that if either
// PeerDrop/Security/Protocol/X3DH.swift or DoubleRatchet.swift ever drifts
// from this math, the corresponding vector tests catch the divergence.
//
// X3DH math mirrors PeerDrop/Security/Protocol/X3DH.swift exactly:
//  - DH outputs extracted via no-op HKDF (empty salt, empty sharedInfo, 32-byte output)
//  - 3 DH outputs concatenated: DH1=DH(IK_A,SPK_B), DH2=DH(EK_A,IK_B), DH3=DH(EK_A,SPK_B)
//  - DH4=DH(EK_A,OPK_B) appended when OPK present (all 20 vectors include OPK)
//  - HKDF-Extract: PRK = HMAC-SHA256(salt=0x00*32, IKM=concatenated DH outputs)
//  - HKDF-Expand T(1): HMAC-SHA256(PRK, info || 0x01)          → rootKey
//  - HKDF-Expand T(2): HMAC-SHA256(PRK, T(1) || info || 0x02)  → chainKey
//  - info = "PeerDrop-X3DH-v1" (UTF-8)
//
// Double Ratchet math mirrors PeerDrop/Security/Protocol/DoubleRatchet.swift:
//  - dhRatchetStep: DH via no-op HKDF → HMAC-HKDF-Extract → HKDF-Expand T(1)/T(2)
//    - salt = current root key, info = "PeerDrop-Ratchet-v1"
//  - symmetricRatchetStep: msgKey = HMAC(ck, 0x01), newChain = HMAC(ck, 0x02)
//  - Encryption: AES-256-GCM (random nonce baked into .combined bytes)
//  - Ratchet variant: Alice→Bob one-directional sequences only.
//    Ping-pong vectors would require seeding the random PrivateKey() calls inside
//    decrypt()'s DH ratchet step; that requires a test seam not present in the
//    current production DoubleRatchet. All 30 vectors test the symmetric ratchet
//    chain + Bob's first-message DH ratchet trigger in a fully reproducible way.
//    Bob's decryption derives the receive chain deterministically from:
//      dhRatchetStep(rootKey=seeded, myKey=seeded_bob_key, theirKey=alice_pub_from_msg)
//    Alice's ratchet public key is stored in every frozen RatchetMessage, so Bob
//    can always recreate the exact receive chain used at generation time.

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

// MARK: - Double Ratchet math (inlined from DoubleRatchet.swift — must stay in sync)

/// One complete Double Ratchet session state. Mirrors the fields in
/// DoubleRatchetSession but all as raw Data so we avoid linking the app target.
final class RatchetSession {
    var myRatchetKey: Curve25519.KeyAgreement.PrivateKey
    var theirRatchetKey: Curve25519.KeyAgreement.PublicKey?
    var rootKey: Data                  // 32 bytes
    var sendChainKey: Data?            // 32 bytes
    var receiveChainKey: Data?         // 32 bytes
    var sendCounter: UInt32 = 0
    var receiveCounter: UInt32 = 0
    var previousSendCounter: UInt32 = 0

    init(rootKey: Data, myRatchetKey: Curve25519.KeyAgreement.PrivateKey) {
        self.rootKey = rootKey
        self.myRatchetKey = myRatchetKey
    }
}

/// Mirrors DoubleRatchetSession.dhRatchetStep exactly.
func dhRatchetStep(
    rootKey: Data,
    myKey: Curve25519.KeyAgreement.PrivateKey,
    theirKey: Curve25519.KeyAgreement.PublicKey
) -> (newRootKey: Data, chainKey: Data) {
    let shared = try! myKey.sharedSecretFromKeyAgreement(with: theirKey)
    // Same CryptoKit workaround as production: extract 32 bytes via no-op HKDF
    let sharedData: Data = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: Data(), sharedInfo: Data(), outputByteCount: 32
    ).withUnsafeBytes { Data($0) }

    let info = "PeerDrop-Ratchet-v1".data(using: .utf8)!
    let prk = Data(HMAC<SHA256>.authenticationCode(
        for: sharedData,
        using: SymmetricKey(data: rootKey)
    ))
    let prkKey = SymmetricKey(data: prk)

    var t1Input = info; t1Input.append(0x01)
    let t1 = Data(HMAC<SHA256>.authenticationCode(for: t1Input, using: prkKey))

    var t2Input = t1; t2Input.append(contentsOf: info); t2Input.append(0x02)
    let t2 = Data(HMAC<SHA256>.authenticationCode(for: t2Input, using: prkKey))

    return (t1, t2)
}

/// Mirrors DoubleRatchetSession.symmetricRatchetStep exactly.
func symmetricRatchetStep(chainKey: Data) -> (messageKey: Data, newChainKey: Data) {
    let msgKey = Data(HMAC<SHA256>.authenticationCode(
        for: Data([0x01]), using: SymmetricKey(data: chainKey)
    ))
    let newChain = Data(HMAC<SHA256>.authenticationCode(
        for: Data([0x02]), using: SymmetricKey(data: chainKey)
    ))
    return (msgKey, newChain)
}

/// A frozen ratchet message ready for JSON serialization.
struct FrozenRatchetMessage: Encodable {
    let ratchet_key: String   // base64 of Alice's current ratchet public key
    let counter: UInt32
    let previous_counter: UInt32
    let ciphertext: String    // base64 of AES-256-GCM .combined bytes (nonce+ct+tag)
    let plaintext_hex: String // expected plaintext, stored for test assertion
}

/// Encrypt one message from Alice's RatchetSession, producing a FrozenRatchetMessage.
/// Mirrors DoubleRatchetSession.encrypt exactly.
func ratchetEncrypt(session: RatchetSession, plaintext: Data) throws -> FrozenRatchetMessage {
    guard let chainKey = session.sendChainKey else {
        fatalError("ratchetEncrypt called with no sendChainKey")
    }
    let (messageKey, newChainKey) = symmetricRatchetStep(chainKey: chainKey)
    session.sendChainKey = newChainKey

    let sealedBox = try AES.GCM.seal(plaintext, using: SymmetricKey(data: messageKey))
    guard let combined = sealedBox.combined else {
        fatalError("AES.GCM.seal returned no combined data")
    }

    let msg = FrozenRatchetMessage(
        ratchet_key:      toBase64(session.myRatchetKey.publicKey.rawRepresentation),
        counter:          session.sendCounter,
        previous_counter: session.previousSendCounter,
        ciphertext:       toBase64(combined),
        plaintext_hex:    toHex(plaintext)
    )
    session.sendCounter += 1
    return msg
}

/// JSON structure for one ratchet vector.
struct RatchetVectorJSON: Encodable {
    let name: String
    let inputs: Inputs
    let messages: [FrozenRatchetMessage]

    struct Inputs: Encodable {
        /// Hex seed used to derive the shared root key (32 bytes via SHA-256).
        let root_key_seed: String
        /// Hex seed for Alice's initial ratchet key (the key she generates inside
        /// initializeAsInitiator in production; here seeded for reproducibility).
        let alice_initial_ratchet_seed: String
        /// Hex seed for Bob's initial ratchet key (the SPK stand-in passed to
        /// initializeAsResponder and initializeAsInitiator in production).
        let bob_initial_ratchet_seed: String
    }
}

/// Derive a 32-byte root key from a seed using SHA-256.
/// This gives a deterministic SymmetricKey without linking the app target.
func deriveRootKey(seed: Data) -> Data {
    Data(SHA256.hash(data: seed))
}

/// Generate all 30 ratchet vectors into `outputDir`.
func generateRatchetVectors(outputDir: String, encoder: JSONEncoder) throws {
    try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    // Sequence blueprints: (vectorIndex, messageLengths in bytes for each Alice send)
    // All vectors are Alice→Bob one-directional. See file header for rationale.
    let blueprints: [(idx: Int, lengths: [Int])] = [
        // Vectors 001–010: short to medium one-direction chains (1–10 messages)
        (1,  [4]),
        (2,  [4, 4]),
        (3,  [4, 4, 4]),
        (4,  [8, 4, 8, 4]),
        (5,  [4, 4, 4, 4, 4]),
        (6,  [16, 8, 4, 8, 16, 4]),
        (7,  [4, 8, 12, 8, 4, 8, 4]),
        (8,  [4, 4, 4, 4, 4, 4, 4, 4]),
        (9,  [8, 8, 8, 8, 8, 8, 8, 8, 8]),
        (10, [4, 4, 8, 4, 4, 8, 4, 4, 8, 4]),
        // Vectors 011–020: longer chains (11–20 messages), exercising more symmetric ratchet steps
        (11, [4, 8, 4, 8, 4, 8, 4, 8, 4, 8, 4]),
        (12, [16, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 16]),
        (13, [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]),
        (14, [8, 4, 8, 4, 8, 4, 8, 4, 8, 4, 8, 4, 8, 4]),
        (15, [4, 8, 16, 8, 4, 8, 16, 8, 4, 8, 16, 8, 4, 8, 4]),
        (16, [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]),
        (17, [8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8]),
        (18, [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]),
        (19, [4, 8, 4, 8, 4, 8, 4, 8, 4, 8, 4, 8, 4, 8, 4, 8, 4, 8, 4]),
        (20, [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]),
        // Vectors 021–030: varied seeds, different message byte content
        (21, [4, 4, 4]),
        (22, [8, 8, 8, 8]),
        (23, [4, 16, 4, 16, 4]),
        (24, [8, 4, 4, 4, 4, 8]),
        (25, [4, 4, 4, 4, 4, 4, 4]),
        (26, [16, 16, 16, 16, 16, 16, 16, 16]),
        (27, [8, 4, 8, 4, 8, 4, 8, 4, 8]),
        (28, [4, 4, 4, 4, 4, 4, 4, 4, 4, 4]),
        (29, [4, 8, 12, 16, 12, 8, 4]),
        (30, [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]),
    ]

    for bp in blueprints {
        let n = bp.idx
        let rootSeed   = makeSeed(vectorIndex: n, fieldByte: 0x11)
        let aliceSeed  = makeSeed(vectorIndex: n, fieldByte: 0x22)
        let bobSeed    = makeSeed(vectorIndex: n, fieldByte: 0x33)

        let rootKey    = deriveRootKey(seed: rootSeed)
        let aliceKey   = curve25519AgreementKey(seed: aliceSeed)
        let bobKey     = curve25519AgreementKey(seed: bobSeed)

        // Alice: initializeAsInitiator equivalent.
        // Production generates a random ratchet key inside that function, but here
        // we seed it so the test can reconstruct the same Alice session state.
        let aliceSession = RatchetSession(rootKey: rootKey, myRatchetKey: aliceKey)
        aliceSession.theirRatchetKey = bobKey.publicKey
        let (newRootKey, sendChain) = dhRatchetStep(
            rootKey: rootKey,
            myKey: aliceKey,
            theirKey: bobKey.publicKey
        )
        aliceSession.rootKey = newRootKey
        aliceSession.sendChainKey = sendChain

        // Generate each plaintext deterministically from the sequence index + vector index.
        var messages: [FrozenRatchetMessage] = []
        for (msgIdx, byteLen) in bp.lengths.enumerated() {
            // Build a deterministic plaintext: repeating bytes of (n ^ msgIdx)
            let fillByte = UInt8((n ^ msgIdx) & 0xFF)
            let plaintext = Data(repeating: fillByte, count: byteLen)
            let frozen = try ratchetEncrypt(session: aliceSession, plaintext: plaintext)
            messages.append(frozen)
        }

        let vecName = String(format: "ratchet-%03d", n)
        let vector = RatchetVectorJSON(
            name: vecName,
            inputs: RatchetVectorJSON.Inputs(
                root_key_seed:               toHex(rootSeed),
                alice_initial_ratchet_seed:  toHex(aliceSeed),
                bob_initial_ratchet_seed:    toHex(bobSeed)
            ),
            messages: messages
        )

        let jsonData = try encoder.encode(vector)
        let filename = String(format: "ratchet-%03d.json", n)
        let outPath = (outputDir as NSString).appendingPathComponent(filename)
        try jsonData.write(to: URL(fileURLWithPath: outPath))
        print("Generated \(filename) (\(messages.count) messages)")
    }
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: swift tools/generate-test-vectors.swift <output-dir>\n", stderr)
    exit(1)
}

let outputDir = args[1]

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

// ── X3DH vectors ──────────────────────────────────────────────────────────────
let x3dhDir = (outputDir as NSString).appendingPathComponent("x3dh")
try FileManager.default.createDirectory(atPath: x3dhDir, withIntermediateDirectories: true)

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
    let outPath = (x3dhDir as NSString).appendingPathComponent(filename)
    try jsonData.write(to: URL(fileURLWithPath: outPath))
    print("Generated x3dh/\(filename)")
}

print("Done — 20 X3DH vectors written to \(x3dhDir)")

// ── Double Ratchet vectors ────────────────────────────────────────────────────
let ratchetDir = (outputDir as NSString).appendingPathComponent("ratchet")
try generateRatchetVectors(outputDir: ratchetDir, encoder: encoder)
print("Done — 30 ratchet vectors written to \(ratchetDir)")
