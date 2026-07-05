import XCTest
import CryptoKit
@testable import PeerDropSecurity

/// Fuzz targets for the Double Ratchet decrypt surface — v5.4.1 BLOCK item
/// (`docs/release/v5.4.0-readiness.md` §3 Gap A).
///
/// Invariants asserted on every mutated / forged input:
///  1. `decrypt` never crashes or hangs.
///  2. Failure paths only throw documented categories (`DoubleRatchetError`,
///     `CryptoKitError` from AES-GCM auth / Curve25519 construction) — and
///     never return plaintext for a tampered ciphertext.
///  3. The C3 skipped-keys cache stays bounded under a stream of forged
///     headers (LRU + per-decrypt maxSkip cap) — no unbounded growth.
///
/// Determinism: mutation schedules are fully seeded. `initializeAsInitiator`
/// and `encrypt` use fresh CryptoKit randomness internally (ratchet keygen,
/// GCM nonce), so the *target* wire bytes vary between runs — every failure
/// message therefore dumps the exact mutated input (base64) for replay.
///
/// Iteration budget: `FUZZ_ITERATIONS` env var via `FuzzConfig.iterations`
/// (10K default; the scheduled fuzz CI job exports 100000).
final class RatchetFuzzTests: XCTestCase {

    /// Mirror of `DoubleRatchetSession.maxSkip` (private). A single decrypt
    /// can cache at most this many keys per chain (old chain + new chain).
    private static let maxSkipPerChain = 200

    private func makeSessionPair(seed: UInt64) throws -> (alice: DoubleRatchetSession, bob: DoubleRatchetSession) {
        let seedBytes = FuzzInputs.seedData(seed, salt: 0x5E)
        let rootKey = SymmetricKey(data: SHA256.hash(data: seedBytes))
        let bobRatchetKey = DeterministicCrypto.curve25519AgreementKey(seed: seedBytes)
        let bob = DoubleRatchetSession.initializeAsResponder(rootKey: rootKey, myRatchetKey: bobRatchetKey)
        let alice = try DoubleRatchetSession.initializeAsInitiator(rootKey: rootKey, theirRatchetKey: bobRatchetKey.publicKey)
        return (alice, bob)
    }

    // MARK: - Target 1: mutated wire message (header + ciphertext)

    func test_fuzz_ratchetMessage_wire_neverCrashes_neverReturnsForgedPlaintext() throws {
        let (alice, bob) = try makeSessionPair(seed: 0x0A7C_4E71)
        let plaintext = Data("ratchet-fuzz-canary-v1 0123456789abcdef0123456789abcdef".utf8)
        let message = try alice.encrypt(plaintext)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let wire = try encoder.encode(message)
        // Snapshot Bob BEFORE any decrypt: decrypt mutates session state in
        // place, so each iteration replays against an identical pristine copy.
        let bobSnapshot = try encoder.encode(bob)
        let decoder = JSONDecoder()

        // Sanity: the unmutated round-trip must work (guards fixture rot).
        let sanityBob = try decoder.decode(DoubleRatchetSession.self, from: bobSnapshot)
        XCTAssertEqual(try sanityBob.decrypt(message, policy: .bundledDefault, metrics: nil), plaintext)

        let fuzzSeed: UInt64 = 0x8A7C_0001
        FuzzHarness.runIndexed(
            target: wire,
            iterations: FuzzConfig.iterations,
            seed: fuzzSeed,
            operators: FuzzHarness.Mutator.allCases
        ) { iteration, mutated in
            func context() -> String {
                "iteration \(iteration), seed \(fuzzSeed), input(base64) \(mutated.base64EncodedString())"
            }

            // Rejecting broken JSON at the wire layer is a pass.
            guard let forged = try? decoder.decode(RatchetMessage.self, from: mutated) else { return }
            guard let freshBob = try? decoder.decode(DoubleRatchetSession.self, from: bobSnapshot) else {
                XCTFail("pristine session snapshot failed to decode — harness bug")
                return
            }

            do {
                let out = try freshBob.decrypt(forged, policy: .bundledDefault, metrics: nil)
                // Success is only legal when the mutation was semantically
                // neutral (e.g. inserted JSON whitespace, or a field unused on
                // this decrypt path such as previousCounter): the plaintext
                // must be byte-identical. Anything else means AES-GCM
                // authentication was bypassed.
                if out != plaintext {
                    XCTFail("mutated wire decrypted to DIFFERENT plaintext — AEAD failure. \(context())")
                }
            } catch is CryptoKitError {
                // GCM auth failure / malformed sealed box / bad ratchet key
                // length — documented safe-fail.
            } catch is DoubleRatchetSession.DoubleRatchetError {
                // noReceiveChain / tooManySkippedMessages — documented safe-fail.
            } catch {
                XCTFail("undocumented decrypt error \(error). \(context())")
            }
        }
    }

    // MARK: - Target 2: forged headers must not blow up the skipped-key cache (C3)

    func test_fuzz_forgedHeaders_skippedKeyCache_staysBounded() throws {
        let (alice, bob) = try makeSessionPair(seed: 0x0A7C_4E72)
        // Prime Bob with one real message so a receive chain exists.
        let primer = try alice.encrypt(Data("primer".utf8))
        _ = try bob.decrypt(primer, policy: .bundledDefault, metrics: nil)

        let policy = SecurityPolicy.bundledDefault
        // Pool of valid-but-hostile ratchet keys. Reuse means consecutive
        // picks exercise both the same-chain and the new-chain (DH ratchet)
        // paths deterministically.
        let keyPool: [Data] = (0..<16).map {
            DeterministicCrypto.curve25519AgreementKey(seed: FuzzInputs.seedData(0xFEED, salt: UInt8($0)))
                .publicKey.rawRepresentation
        }

        let fuzzSeed: UInt64 = 0x8A7C_0002
        var rng = PropertyTest.SeededRNG(seed: fuzzSeed)

        for iteration in 0..<FuzzConfig.iterations {
            let forged = RatchetMessage(
                ratchetKey: keyPool[Int(rng.next() % UInt64(keyPool.count))],
                counter: UInt32(rng.next() % 64),
                previousCounter: UInt32(rng.next() % 64),
                // 0..<64 bytes: covers under-length sealed boxes (<28B, throws
                // incorrectParameterSize) and auth-failing random ciphertext.
                ciphertext: FuzzInputs.randomData(count: Int(rng.next() % 64), rng: &rng)
            )

            do {
                _ = try bob.decrypt(forged, policy: policy, metrics: nil)
                // Random ciphertext passing GCM authentication = broken AEAD.
                XCTFail("forged ciphertext decrypted successfully — iteration \(iteration), seed \(fuzzSeed)")
                return
            } catch is CryptoKitError {
            } catch is DoubleRatchetSession.DoubleRatchetError {
            } catch {
                XCTFail("undocumented error \(error) — iteration \(iteration), seed \(fuzzSeed)")
                return
            }

            // C3 invariant: the LRU pass runs at the top of every decrypt and
            // a single decrypt can add at most maxSkip keys per chain (old +
            // new) after that pass — so the cache may never exceed
            // maxCount + 2 * maxSkip at rest.
            let bound = policy.skippedKeyMaxCount + 2 * Self.maxSkipPerChain
            if bob.skippedKeysCountForTesting > bound {
                XCTFail("skipped-key cache exploded: \(bob.skippedKeysCountForTesting) > \(bound) — iteration \(iteration), seed \(fuzzSeed)")
                return
            }
        }

        // A final LRU sweep must bring the cache back under the policy cap.
        _ = bob.evictLRUSkippedKeys(policy: policy)
        XCTAssertLessThanOrEqual(bob.skippedKeysCountForTesting, policy.skippedKeyMaxCount)
    }

    // MARK: - Target 3: mutated persisted session state

    func test_fuzz_persistedSession_decode_neverCrashes() throws {
        let (alice, bob) = try makeSessionPair(seed: 0x0A7C_4E73)
        // Build non-trivial state: decrypt an out-of-order message so the
        // snapshot contains chains, counters AND skipped-key entries.
        _ = try alice.encrypt(Data("m0".utf8))
        let m1 = try alice.encrypt(Data("m1".utf8))
        let m2 = try alice.encrypt(Data("m2".utf8))
        _ = try bob.decrypt(m2, policy: .bundledDefault, metrics: nil)  // skips m0, m1

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = try encoder.encode(bob)
        let decoder = JSONDecoder()
        let expectedM1 = Data("m1".utf8)

        let fuzzSeed: UInt64 = 0x8A7C_0003
        FuzzHarness.runIndexed(
            target: snapshot,
            iterations: FuzzConfig.iterations,
            seed: fuzzSeed,
            operators: FuzzHarness.Mutator.allCases
        ) { iteration, mutated in
            func context() -> String {
                "iteration \(iteration), seed \(fuzzSeed), input(base64) \(mutated.base64EncodedString())"
            }

            do {
                let session = try decoder.decode(DoubleRatchetSession.self, from: mutated)
                // Decode survived the mutation — the object must still behave
                // safely: decrypting a genuine message either yields the exact
                // original plaintext (mutation was semantically neutral or hit
                // unrelated state) or fails through a documented error.
                do {
                    let out = try session.decrypt(m1, policy: .bundledDefault, metrics: nil)
                    if out != expectedM1 {
                        XCTFail("corrupted session returned WRONG plaintext for a genuine message — \(context())")
                    }
                } catch is CryptoKitError {
                } catch is DoubleRatchetSession.DoubleRatchetError {
                } catch {
                    XCTFail("undocumented decrypt error \(error) — \(context())")
                }
            } catch is DecodingError {
                // Broken JSON / type mismatch — documented safe-fail.
            } catch is CryptoKitError {
                // Wrong-length key material inside init(from:) — safe-fail.
            } catch {
                XCTFail("undocumented decode error \(error) — \(context())")
            }
        }
    }
}
