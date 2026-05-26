import XCTest
import CryptoKit
@testable import PeerDropSecurity

/// Replays 10 frozen out-of-order Double Ratchet vectors against the production
/// `DoubleRatchetSession`, verifying that the `skippedKeys` cache correctly
/// handles messages received in scrambled order.
///
/// Vector layout (Alice→Bob one-directional, seeded keys):
///   - root_key_seed               → SHA-256 digest = 32-byte root key
///   - alice_initial_ratchet_seed  → DeterministicCrypto.curve25519AgreementKey(seed:)
///   - bob_initial_ratchet_seed    → same
///   - alice_plaintexts_hex[]      → expected plaintexts in Alice's send order
///   - bob_receive_order[]         → permutation of [0..N-1]: indices in the order
///                                   Bob receives them
///   - messages[]                  → frozen ciphertexts in Alice's send order
///
/// For each vector the test:
///   1. Constructs Bob as DoubleRatchetSession.initializeAsResponder (seeded)
///   2. Replays messages in `bob_receive_order` order (not send order)
///   3. Asserts each decrypted plaintext matches alice_plaintexts_hex[i]
///   4. After all N messages, asserts bob.skippedKeys is empty (no leaked keys)
final class SkippedKeyVectorTests: XCTestCase {

    // MARK: - JSON model

    private struct SkippedKeyVector: Decodable {
        let name: String
        let inputs: Inputs
        let bob_receive_order: [Int]
        let messages: [FrozenMessage]

        struct Inputs: Decodable {
            let root_key_seed: String
            let alice_initial_ratchet_seed: String
            let bob_initial_ratchet_seed: String
            let alice_plaintexts_hex: [String]
        }

        struct FrozenMessage: Decodable {
            let ratchet_key: String       // base64 of Alice's ratchet public key
            let counter: UInt32
            let previous_counter: UInt32
            let ciphertext: String        // base64 of AES-256-GCM .combined bytes
            let plaintext_hex: String     // expected decrypted bytes (same order as messages[])
        }
    }

    // MARK: - Test entry point

    func test_all_skipped_key_vectors() throws {
        let bundle = Bundle.module

        var loaded = 0
        for n in 1...10 {
            let filename = String(format: "skipped-%03d", n)
            guard let url = bundle.url(forResource: filename, withExtension: "json",
                                       subdirectory: "Resources/skipped-keys")
                          ?? bundle.url(forResource: filename, withExtension: "json")
            else {
                XCTFail("Missing vector file \(filename).json — run xcodegen generate after creating fixtures")
                continue
            }
            let vector: SkippedKeyVector = try TestVectorLoader.load(from: url)
            try replayVector(vector)
            loaded += 1
        }

        XCTAssertEqual(loaded, 10,
            "Expected 10 skipped-key vectors, loaded \(loaded). "
            + "Check PeerDropTests/CryptoTestKit/TestVectors/skipped-keys/ is in the test bundle "
            + "(run xcodegen generate).")
    }

    // MARK: - Private

    private func replayVector(_ v: SkippedKeyVector) throws {
        // Derive root key: SHA-256 of the seed (mirrors generateSkippedKeyVectors).
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

        // Build the full array of frozen RatchetMessage objects (indexed in send order).
        var frozenMessages: [RatchetMessage] = []
        for (idx, frozen) in v.messages.enumerated() {
            guard let ratchetKeyBytes = Data(base64Encoded: frozen.ratchet_key),
                  let ciphertextBytes = Data(base64Encoded: frozen.ciphertext)
            else {
                XCTFail("\(v.name) messages[\(idx)]: base64 decode failed")
                return
            }
            frozenMessages.append(RatchetMessage(
                ratchetKey:      ratchetKeyBytes,
                counter:         frozen.counter,
                previousCounter: frozen.previous_counter,
                ciphertext:      ciphertextBytes
            ))
        }

        // Receive messages in the scrambled order specified by bob_receive_order.
        for receiveStep in v.bob_receive_order.indices {
            let msgIdx = v.bob_receive_order[receiveStep]
            let msg = frozenMessages[msgIdx]
            let expectedHex = v.inputs.alice_plaintexts_hex[msgIdx]

            let decrypted = try bob.decrypt(msg)
            XCTAssertEqual(
                decrypted.hexString, expectedHex,
                "\(v.name) step[\(receiveStep)] msgIdx[\(msgIdx)]: decrypted plaintext mismatch"
            )
        }

        // After all messages are processed, skippedKeys must be empty — no leaked keys.
        XCTAssertTrue(
            bob.skippedKeysIsEmpty,
            "\(v.name): skippedKeys not empty after consuming all \(v.messages.count) messages"
        )
    }
}

// MARK: - Hex convenience (local to this file)

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
