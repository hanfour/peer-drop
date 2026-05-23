import Foundation
import XCTest

/// Lightweight property-testing harness. Each trial gets a seeded RNG so
/// failures are reproducible. Built in-house to avoid a SwiftCheck
/// dependency and keep the CI surface minimal.
public enum PropertyTest {

    /// SplitMix64 — fast, deterministic, no external state. Sufficient for
    /// crypto-test fixture generation (we never use it for production code).
    public struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        public init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
        public mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    public struct FailureReport {
        public let firstFailingSeed: UInt64?
        public let trialsRun: Int
    }

    /// Asserts a property holds for `trials` random inputs. Uses XCTFail
    /// on first failure (with the seed printed for reproducibility).
    public static func forAll(
        trials: Int,
        seed: UInt64,
        file: StaticString = #file,
        line: UInt = #line,
        _ property: (inout SeededRNG) -> Bool
    ) {
        for trial in 0..<trials {
            let trialSeed = seed &+ UInt64(trial)
            var rng = SeededRNG(seed: trialSeed)
            if !property(&rng) {
                XCTFail(
                    "Property failed on trial \(trial), seed \(trialSeed). Reproduce with .forAll(trials: 1, seed: \(trialSeed)).",
                    file: file, line: line
                )
                return
            }
        }
    }

    /// Variant that returns a structured report instead of using XCTFail —
    /// for self-testing the harness itself.
    public static func runCapturingFailure(
        trials: Int,
        seed: UInt64,
        _ property: (inout SeededRNG) -> Bool
    ) -> FailureReport {
        for trial in 0..<trials {
            let trialSeed = seed &+ UInt64(trial)
            var rng = SeededRNG(seed: trialSeed)
            if !property(&rng) {
                return FailureReport(firstFailingSeed: trialSeed, trialsRun: trial + 1)
            }
        }
        return FailureReport(firstFailingSeed: nil, trialsRun: trials)
    }
}
