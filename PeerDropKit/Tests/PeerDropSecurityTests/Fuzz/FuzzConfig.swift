import Foundation

/// Shared iteration budget for the fuzz suites (`X3DHFuzzTests`,
/// `RatchetFuzzTests`).
///
/// - Local / PR CI: defaults to 10K iterations per target.
/// - Scheduled fuzz CI (`.github/workflows/fuzz-nightly.yml`): exports
///   `FUZZ_ITERATIONS=100000` to satisfy the spec §8.5 gate
///   (see `docs/release/v5.4.0-readiness.md` item 3).
///
/// `PolicyFuzzTests` predates this knob and stays pinned at its original
/// hard-coded 10K — its behavior is intentionally left untouched.
enum FuzzConfig {
    static var iterations: Int {
        if let raw = ProcessInfo.processInfo.environment["FUZZ_ITERATIONS"],
           let parsed = Int(raw), parsed > 0 {
            return parsed
        }
        return 10_000
    }
}

/// Deterministic input factories shared by the fuzz suites.
enum FuzzInputs {

    /// 32-byte seed block: `seed` big-endian in the first 8 bytes, `salt`
    /// repeated in the remaining 24. Pure function — reproducible key
    /// derivation via `DeterministicCrypto`.
    static func seedData(_ seed: UInt64, salt: UInt8) -> Data {
        var data = Data(repeating: salt, count: 32)
        withUnsafeBytes(of: seed.bigEndian) { data.replaceSubrange(0..<8, with: $0) }
        return data
    }

    /// `count` bytes drawn from the seeded RNG — reproducible random blobs.
    static func randomData(count: Int, rng: inout PropertyTest.SeededRNG) -> Data {
        var data = Data(capacity: count)
        for _ in 0..<count {
            data.append(UInt8(rng.next() & 0xFF))
        }
        return data
    }
}
