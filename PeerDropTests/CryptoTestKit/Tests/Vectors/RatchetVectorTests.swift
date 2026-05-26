import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDrop

/// Replays 30 frozen Double Ratchet vectors against the production
/// `DoubleRatchetSession`, verifying that every ciphertext in the JSON
/// decrypts to the expected plaintext byte-for-byte.
///
/// Vector layout (Alice→Bob one-directional, seeded keys):
///   - root_key_seed               → SHA-256 digest = 32-byte root key
///   - alice_initial_ratchet_seed  → DeterministicCrypto.curve25519AgreementKey(seed:)
///   - bob_initial_ratchet_seed    → same
///   - messages[]                  → each carries a frozen RatchetMessage plus
///                                   plaintext_hex for assertion
///
/// Bob is reconstructed as an DoubleRatchetSession.initializeAsResponder with
/// the seeded root key and seeded ratchet private key — exactly the state the
/// generator used. Alice's ratchet public key is stored inside each frozen
/// message's `ratchet_key` field, so Bob's DH ratchet step on the first message
/// is deterministic and reproducible.
final class RatchetVectorTests: XCTestCase {

    // MARK: - JSON model

    private struct RatchetVector: Decodable {
        let name: String
        let inputs: Inputs
        let messages: [FrozenMessage]

        struct Inputs: Decodable {
            let root_key_seed: String
            let alice_initial_ratchet_seed: String
            let bob_initial_ratchet_seed: String
        }

        struct FrozenMessage: Decodable {
            let ratchet_key: String      // base64 of Alice's ratchet public key
            let counter: UInt32
            let previous_counter: UInt32
            let ciphertext: String       // base64 of AES-256-GCM .combined bytes
            let plaintext_hex: String    // expected decrypted bytes
        }
    }

    // MARK: - Test entry point

    func test_all_ratchet_vectors() throws {
        let bundle = Bundle(for: type(of: self))

        var loaded = 0
        for n in 1...30 {
            let filename = String(format: "ratchet-%03d", n)
            guard let url = bundle.url(forResource: filename, withExtension: "json",
                                       subdirectory: "ratchet")
                          ?? bundle.url(forResource: filename, withExtension: "json")
            else {
                XCTFail("Missing vector file \(filename).json — run xcodegen generate after creating fixtures")
                continue
            }
            let vector: RatchetVector = try TestVectorLoader.load(from: url)
            try replayVector(vector)
            loaded += 1
        }

        XCTAssertEqual(loaded, 30,
            "Expected 30 ratchet vectors, loaded \(loaded). "
            + "Check PeerDropTests/CryptoTestKit/TestVectors/ratchet/ is in the test bundle "
            + "(run xcodegen generate).")
    }

    // MARK: - Private

    private func replayVector(_ v: RatchetVector) throws {
        // Derive root key: SHA-256 of the seed (mirrors generateRatchetVectors in generator).
        let rootSeed = Data(hex: v.inputs.root_key_seed)
        let rootKeyData = Data(SHA256.hash(data: rootSeed))
        let rootKey = SymmetricKey(data: rootKeyData)

        // Bob: responder with seeded private key, no chains yet.
        let bobKeyData = Data(hex: v.inputs.bob_initial_ratchet_seed)
        let bobPriv = DeterministicCrypto.curve25519AgreementKey(seed: bobKeyData)
        let bob = DoubleRatchetSession.initializeAsResponder(
            rootKey: rootKey,
            myRatchetKey: bobPriv
        )

        // Replay each frozen message.
        for (idx, frozen) in v.messages.enumerated() {
            // Reconstruct the RatchetMessage from stored fields.
            guard let ratchetKeyBytes = Data(base64Encoded: frozen.ratchet_key),
                  let ciphertextBytes = Data(base64Encoded: frozen.ciphertext)
            else {
                XCTFail("\(v.name) message[\(idx)]: base64 decode failed")
                continue
            }

            let msg = RatchetMessage(
                ratchetKey:      ratchetKeyBytes,
                counter:         frozen.counter,
                previousCounter: frozen.previous_counter,
                ciphertext:      ciphertextBytes
            )

            let decrypted = try bob.decrypt(msg)
            let expectedHex = frozen.plaintext_hex
            XCTAssertEqual(
                decrypted.hexString, expectedHex,
                "\(v.name) message[\(idx)]: decrypted plaintext mismatch"
            )
        }
    }
}

// MARK: - Hex convenience (local to this file; mirrors X3DHVectorTests.swift)

private extension Data {
    init(hex: String) {
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { break }
            data.append(byte)
            idx = next
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
