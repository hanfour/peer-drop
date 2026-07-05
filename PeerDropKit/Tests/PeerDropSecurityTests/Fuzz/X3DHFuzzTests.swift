import XCTest
import CryptoKit
@testable import PeerDropSecurity

/// Fuzz targets for the X3DH input surface — v5.4.1 BLOCK item
/// (`docs/release/v5.4.0-readiness.md` §3 Gap A).
///
/// Invariants asserted on every mutated input:
///  1. Never crashes or hangs.
///  2. Malformed input is rejected via a documented error category (or a
///     boolean verification failure) — never an undocumented error type.
///  3. A bundle whose signature-protected fields (signing key, SPK public
///     key, SPK timestamp) were tampered with never passes validation, so a
///     session is never established from tampered signed material.
///     (Stripping BOTH C1 timestamp fields downgrades to `.legacy` — that is
///     the documented bundled-default compat path, not a fuzz failure.)
///
/// Determinism: mutation schedules are fully seeded (`FuzzHarness` /
/// `PropertyTest.SeededRNG`), and key material derives from
/// `DeterministicCrypto`. CryptoKit's Ed25519 *signing* is randomized, so the
/// fixture's signature bytes vary between runs — every failure message
/// therefore dumps the exact mutated input (base64) for byte-exact replay.
///
/// Iteration budget: `FUZZ_ITERATIONS` env var via `FuzzConfig.iterations`
/// (10K default; the scheduled fuzz CI job exports 100000).
final class X3DHFuzzTests: XCTestCase {

    // Fixed wall clock so C1 age math is reproducible across runs.
    private static let fixedNow = Date(timeIntervalSince1970: 1_751_500_000)

    // Strict policy: C1 reject + C2 fail-closed — exercises the hard-reject
    // branches that the bundled default (legacy/warn) never reaches.
    private static let rejectPolicy = SecurityPolicy(
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

    // MARK: - Fixture

    private struct BundleFixture {
        let json: Data
        let signingKeyRaw: Data
        let spkPublicKey: Data
        let timestamp: UInt64
    }

    /// Fully valid PreKeyBundle (fresh C1 timestamp, one OPK), serialized
    /// with sorted keys so the mutation offsets are stable within a run.
    private func makeBundleFixture(seed: UInt64) throws -> BundleFixture {
        let identityKA = DeterministicCrypto.curve25519AgreementKey(seed: FuzzInputs.seedData(seed, salt: 0x1D))
        let signingPriv = DeterministicCrypto.curve25519SigningKey(seed: FuzzInputs.seedData(seed, salt: 0x51))
        let spkKA = DeterministicCrypto.curve25519AgreementKey(seed: FuzzInputs.seedData(seed, salt: 0x5B))
        let opkKA = DeterministicCrypto.curve25519AgreementKey(seed: FuzzInputs.seedData(seed, salt: 0x0B))

        let spkPub = spkKA.publicKey.rawRepresentation
        let legacySig = try signingPriv.signature(for: spkPub)

        // 5 days old — comfortably inside the 21-day freshness window.
        let ts = UInt64(Self.fixedNow.timeIntervalSince1970) - 5 * 86_400
        var payload = spkPub
        var beTs = ts.bigEndian
        payload.append(Data(bytes: &beTs, count: 8))
        let tsSig = try signingPriv.signature(for: payload)

        let bundle = PreKeyBundle(
            identityKey: identityKA.publicKey.rawRepresentation,
            signingKey: signingPriv.publicKey.rawRepresentation,
            signedPreKey: PublicSignedPreKey(
                id: 7,
                publicKey: spkPub,
                signature: legacySig,
                timestamp: Self.fixedNow
            ),
            oneTimePreKeys: [
                PublicOneTimePreKey(id: 1, publicKey: opkKA.publicKey.rawRepresentation)
            ],
            signedPreKeyTimestamp: ts,
            signedPreKeyTimestampSignature: tsSig
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return BundleFixture(
            json: try encoder.encode(bundle),
            signingKeyRaw: signingPriv.publicKey.rawRepresentation,
            spkPublicKey: spkPub,
            timestamp: ts
        )
    }

    // MARK: - Target 1: full wire-decode → validate → key-agreement pipeline

    func test_fuzz_preKeyBundle_wire_neverCrashes_neverAcceptsTamperedSignedFields() throws {
        let fixture = try makeBundleFixture(seed: 0xB0B5_EED5)
        let aliceIK = DeterministicCrypto.curve25519AgreementKey(seed: FuzzInputs.seedData(0xA11CE, salt: 0x01))
        let aliceEK = DeterministicCrypto.curve25519AgreementKey(seed: FuzzInputs.seedData(0xA11CE, salt: 0x02))
        let decoder = JSONDecoder()
        let fuzzSeed: UInt64 = 0x3D4A_0001

        FuzzHarness.runIndexed(
            target: fixture.json,
            iterations: FuzzConfig.iterations,
            seed: fuzzSeed,
            operators: FuzzHarness.Mutator.allCases
        ) { iteration, mutated in
            func context() -> String {
                "iteration \(iteration), seed \(fuzzSeed), input(base64) \(mutated.base64EncodedString())"
            }

            // Stage 1 — wire decode. Rejecting broken JSON is a pass.
            guard let bundle = try? decoder.decode(PreKeyBundle.self, from: mutated) else { return }

            // Stage 2 — signing-key construction (wrong length ⇒ rejected).
            guard let signingPub = try? Curve25519.Signing.PublicKey(rawRepresentation: bundle.signingKey) else { return }

            // Stage 3 — legacy SPK signature (`false` ⇒ rejected).
            guard bundle.signedPreKey.verify(with: signingPub) else { return }

            // Stage 4 — C1 freshness gate under the strict (reject) policy.
            let peerVersion: PeerVersion
            do {
                peerVersion = try X3DH.verifyBundleFreshness(
                    signedPreKeyPublicKey: bundle.signedPreKey.publicKey,
                    signedPreKeyTimestamp: bundle.signedPreKeyTimestamp,
                    signedPreKeyTimestampSignature: bundle.signedPreKeyTimestampSignature,
                    peerSigningKey: signingPub,
                    now: Self.fixedNow,
                    policy: Self.rejectPolicy,
                    metrics: nil
                )
            } catch X3DH.InitiationError.timestampMalformed,
                    X3DH.InitiationError.timestampSignatureInvalid,
                    X3DH.InitiationError.timestampTooOld {
                return  // documented rejection — pass
            } catch {
                XCTFail("verifyBundleFreshness threw undocumented error \(error) — \(context())")
                return
            }

            // Validation fully passed ⇒ the signature-protected fields must be
            // byte-identical to the original. A mutation that altered any of
            // them and still reached here means a signature check is broken.
            // (Signature *bytes* themselves are not asserted — Ed25519
            // malleability variants are out of scope for this invariant.)
            if peerVersion == .v5_4_plus {
                if bundle.signingKey != fixture.signingKeyRaw {
                    XCTFail("tampered signing key passed validation — \(context())")
                    return
                }
                if bundle.signedPreKey.publicKey != fixture.spkPublicKey {
                    XCTFail("tampered SPK public key passed both signatures — \(context())")
                    return
                }
                if bundle.signedPreKeyTimestamp != fixture.timestamp {
                    XCTFail("tampered SPK timestamp passed the C1 signature — \(context())")
                    return
                }
            }
            // peerVersion == .legacy (both C1 fields stripped by the mutation)
            // is the documented backward-compat downgrade — not a fuzz failure.

            // Stage 5 — key agreement with whatever keys decoded. Must not
            // crash; only documented errors allowed.
            guard let theirIK = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.identityKey),
                  let theirSPK = try? bundle.signedPreKey.agreementPublicKey() else { return }
            let theirOPK = bundle.oneTimePreKeys.first.flatMap { try? $0.agreementPublicKey() }

            do {
                let result = try X3DH.initiatorKeyAgreement(
                    myIdentityKey: aliceIK,
                    myEphemeralKey: aliceEK,
                    theirIdentityKey: theirIK,
                    theirSignedPreKey: theirSPK,
                    theirOneTimePreKey: theirOPK,
                    peerVersion: peerVersion,
                    policy: Self.rejectPolicy,
                    metrics: nil
                )
                let rootBytes = result.rootKey.withUnsafeBytes { Data($0) }
                if rootBytes.count != 32 {
                    XCTFail("key agreement produced \(rootBytes.count)-byte root key — \(context())")
                }
            } catch X3DH.InitiationError.opkExhausted {
                // OPK lost to the mutation + strict policy ⇒ fail-closed: pass.
            } catch is CryptoKitError {
                // Degenerate Curve25519 point rejected by corecrypto: pass.
            } catch {
                XCTFail("initiatorKeyAgreement threw undocumented error \(error) — \(context())")
            }
        }
    }

    // MARK: - Target 2: structure-aware tampering of the C1 freshness gate

    func test_fuzz_verifyBundleFreshness_structuredTampering_onlyDocumentedOutcomes() throws {
        let signingPriv = DeterministicCrypto.curve25519SigningKey(seed: FuzzInputs.seedData(0xC1, salt: 0x51))
        let wrongSigner = DeterministicCrypto.curve25519SigningKey(seed: FuzzInputs.seedData(0xC1, salt: 0x52))
        let spkKA = DeterministicCrypto.curve25519AgreementKey(seed: FuzzInputs.seedData(0xC1, salt: 0x5B))
        let spkPub = spkKA.publicKey.rawRepresentation

        let now = Self.fixedNow
        let nowTs = UInt64(now.timeIntervalSince1970)
        let freshTs = nowTs - 5 * 86_400     // inside the 21-day window
        let staleTs = nowTs - 40 * 86_400    // beyond the window
        let futureTs = nowTs + 3_600         // beyond the 60s skew tolerance

        func sign(_ ts: UInt64, with key: Curve25519.Signing.PrivateKey) throws -> Data {
            var payload = spkPub
            var be = ts.bigEndian
            payload.append(Data(bytes: &be, count: 8))
            return try key.signature(for: payload)
        }
        let freshSig = try sign(freshTs, with: signingPriv)
        let staleSig = try sign(staleTs, with: signingPriv)
        let futureSig = try sign(futureTs, with: signingPriv)
        let wrongKeySig = try sign(freshTs, with: wrongSigner)

        enum Expected { case legacy, v54, malformed, sigInvalid, tooOldOrWarn }

        let fuzzSeed: UInt64 = 0x3D4A_0002
        var rng = PropertyTest.SeededRNG(seed: fuzzSeed)

        for iteration in 0..<FuzzConfig.iterations {
            let mode = rng.next() % 10
            let useRejectPolicy = rng.next() & 1 == 0
            let policy = useRejectPolicy ? Self.rejectPolicy : .bundledDefault

            var ts: UInt64? = freshTs
            var sig: Data? = freshSig
            let expected: Expected

            switch mode {
            case 0:  // strip both fields → legacy downgrade (documented)
                ts = nil; sig = nil; expected = .legacy
            case 1:  // timestamp only
                sig = nil; expected = .malformed
            case 2:  // signature only
                ts = nil; expected = .malformed
            case 3:  // single bit flip anywhere in the signature
                var s = freshSig
                let idx = Int(rng.next() % UInt64(s.count))
                s[idx] ^= UInt8(1 << (rng.next() % 8))
                sig = s; expected = .sigInvalid
            case 4:  // truncated signature (0..<64 bytes)
                sig = freshSig.prefix(Int(rng.next() % UInt64(freshSig.count)))
                expected = .sigInvalid
            case 5:  // replacement timestamp under the original signature
                var t = rng.next()
                if t == freshTs { t &+= 1 }
                ts = t; expected = .sigInvalid
            case 6:  // valid signature from the WRONG identity signing key
                sig = wrongKeySig; expected = .sigInvalid
            case 7:  // correctly signed but stale
                ts = staleTs; sig = staleSig; expected = .tooOldOrWarn
            case 8:  // correctly signed but future-dated beyond skew tolerance
                ts = futureTs; sig = futureSig; expected = .tooOldOrWarn
            default: // untouched fresh + valid
                expected = .v54
            }

            func context() -> String {
                "mode \(mode), rejectPolicy \(useRejectPolicy), iteration \(iteration), seed \(fuzzSeed)"
            }

            do {
                let version = try X3DH.verifyBundleFreshness(
                    signedPreKeyPublicKey: spkPub,
                    signedPreKeyTimestamp: ts,
                    signedPreKeyTimestampSignature: sig,
                    peerSigningKey: signingPriv.publicKey,
                    now: now,
                    policy: policy,
                    metrics: nil
                )
                switch expected {
                case .legacy:
                    if version != .legacy { XCTFail("expected .legacy, got \(version) — \(context())"); return }
                case .v54:
                    if version != .v5_4_plus { XCTFail("expected .v5_4_plus, got \(version) — \(context())"); return }
                case .tooOldOrWarn:
                    if useRejectPolicy { XCTFail("stale/future timestamp accepted under reject policy — \(context())"); return }
                    if version != .v5_4_plus { XCTFail("warn-mode stale path returned \(version) — \(context())"); return }
                case .malformed, .sigInvalid:
                    XCTFail("tampered input returned success (\(version)) — \(context())")
                    return
                }
            } catch X3DH.InitiationError.timestampMalformed {
                if expected != .malformed { XCTFail("unexpected timestampMalformed — \(context())"); return }
            } catch X3DH.InitiationError.timestampSignatureInvalid {
                if expected != .sigInvalid { XCTFail("unexpected timestampSignatureInvalid — \(context())"); return }
            } catch X3DH.InitiationError.timestampTooOld {
                if !(expected == .tooOldOrWarn && useRejectPolicy) { XCTFail("unexpected timestampTooOld — \(context())"); return }
            } catch {
                XCTFail("undocumented error \(error) — \(context())")
                return
            }
        }
    }

    // MARK: - Target 3: malformed raw public keys into key agreement

    func test_fuzz_initiatorKeyAgreement_malformedPublicKeys_neverCrashes() {
        let aliceIK = DeterministicCrypto.curve25519AgreementKey(seed: FuzzInputs.seedData(0xA11CE, salt: 0x11))
        let aliceEK = DeterministicCrypto.curve25519AgreementKey(seed: FuzzInputs.seedData(0xA11CE, salt: 0x12))

        // Length mix biased toward 32 (the only valid Curve25519 length) so
        // most iterations reach the DH + KDF path instead of dying at init.
        let lengths = [0, 1, 16, 31, 32, 32, 32, 32, 33, 64]
        let versions: [PeerVersion] = [.legacy, .v5_4_plus, .unknown]

        let fuzzSeed: UInt64 = 0x3D4A_0003
        var rng = PropertyTest.SeededRNG(seed: fuzzSeed)

        for iteration in 0..<FuzzConfig.iterations {
            func randomKeyData() -> Data {
                let len = lengths[Int(rng.next() % UInt64(lengths.count))]
                return FuzzInputs.randomData(count: len, rng: &rng)
            }
            let idData = randomKeyData()
            let spkData = randomKeyData()
            let opkData: Data? = (rng.next() % 4 == 0) ? nil : randomKeyData()
            let version = versions[Int(rng.next() % UInt64(versions.count))]

            // Wrong-length raw keys must be rejected at construction — pass.
            guard let theirIK = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: idData),
                  let theirSPK = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: spkData) else {
                continue
            }
            var theirOPK: Curve25519.KeyAgreement.PublicKey?
            if let opkData {
                guard let opk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: opkData) else {
                    continue  // malformed OPK ⇒ whole bundle rejected upstream
                }
                theirOPK = opk
            }

            // bundledDefault: strict versions fail closed on missing OPK.
            let expectFailClosed = (theirOPK == nil && version != .legacy)

            func context() -> String {
                "iteration \(iteration), seed \(fuzzSeed), version \(version), opkPresent \(theirOPK != nil)"
            }

            do {
                let result = try X3DH.initiatorKeyAgreement(
                    myIdentityKey: aliceIK,
                    myEphemeralKey: aliceEK,
                    theirIdentityKey: theirIK,
                    theirSignedPreKey: theirSPK,
                    theirOneTimePreKey: theirOPK,
                    peerVersion: version,
                    policy: .bundledDefault,
                    metrics: nil
                )
                if expectFailClosed {
                    XCTFail("missing OPK for strict peer did NOT fail closed — \(context())")
                    return
                }
                let root = result.rootKey.withUnsafeBytes { Data($0) }
                let chain = result.chainKey.withUnsafeBytes { Data($0) }
                if root.count != 32 || chain.count != 32 {
                    XCTFail("derived keys have wrong size (\(root.count)/\(chain.count)) — \(context())")
                    return
                }
                if root == chain {
                    XCTFail("root key == chain key — KDF domain separation broken — \(context())")
                    return
                }
            } catch X3DH.InitiationError.opkExhausted {
                if !expectFailClosed {
                    XCTFail("opkExhausted thrown although OPK was present or peer is legacy — \(context())")
                    return
                }
            } catch is CryptoKitError {
                // corecrypto rejected a degenerate point — documented safe-fail.
            } catch {
                XCTFail("undocumented error \(error) — \(context())")
                return
            }
        }
    }
}
