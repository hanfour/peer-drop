import Foundation

/// In-process fuzz harness. Generates deterministic mutations from a
/// seed using `PropertyTest.SeededRNG`, so failures are reproducible.
/// Bounded iterations (default 10K per CI run) — never random walks.
public enum FuzzHarness {

    public enum Mutator: CaseIterable {
        case bitFlip
        case byteInsert
        case byteDelete
        case truncate
    }

    /// Apply a single mutation to `input`. Pure function of `rng` state.
    public static func mutate(
        _ input: Data,
        operator op: Mutator,
        rng: inout PropertyTest.SeededRNG
    ) -> Data {
        switch op {
        case .bitFlip:
            guard !input.isEmpty else { return input }
            var out = input
            let idx = Int(rng.next() % UInt64(input.count))
            let bit: UInt8 = 1 << UInt8(rng.next() % 8)
            out[idx] ^= bit
            return out

        case .byteInsert:
            var out = input
            let idx = Int(rng.next() % UInt64(input.count + 1))
            out.insert(UInt8(rng.next() & 0xFF), at: idx)
            return out

        case .byteDelete:
            guard input.count > 1 else { return input }
            var out = input
            out.remove(at: Int(rng.next() % UInt64(out.count)))
            return out

        case .truncate:
            guard input.count > 1 else { return input }
            let cut = Int(rng.next() % UInt64(input.count))
            return input.prefix(cut)
        }
    }

    /// Run `iterations` rounds of mutation-then-body against `target`. Each
    /// round picks a random operator from `operators`. The `body` closure
    /// is responsible for exercising the parser/decoder under test and
    /// asserting it doesn't crash or hang.
    public static func run(
        target: Data,
        iterations: Int,
        seed: UInt64,
        operators: [Mutator],
        body: (Data) -> Void
    ) {
        var rng = PropertyTest.SeededRNG(seed: seed)
        for _ in 0..<iterations {
            let op = operators[Int(rng.next() % UInt64(operators.count))]
            let mutated = mutate(target, operator: op, rng: &rng)
            body(mutated)
        }
    }
}
