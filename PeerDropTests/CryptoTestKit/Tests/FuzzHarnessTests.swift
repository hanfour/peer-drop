import XCTest
@testable import PeerDrop

final class FuzzHarnessTests: XCTestCase {
    func test_mutate_bitFlip_changesOneByte() {
        let original = Data(repeating: 0xAA, count: 32)
        var rng = PropertyTest.SeededRNG(seed: 42)
        let mutated = FuzzHarness.mutate(original, operator: .bitFlip, rng: &rng)
        XCTAssertEqual(mutated.count, original.count)
        XCTAssertNotEqual(mutated, original)
        // exactly one byte should differ
        let differingBytes = zip(mutated, original).filter { $0 != $1 }.count
        XCTAssertEqual(differingBytes, 1)
    }

    func test_mutate_byteInsert_growsByOne() {
        let original = Data(repeating: 0xAA, count: 32)
        var rng = PropertyTest.SeededRNG(seed: 7)
        let mutated = FuzzHarness.mutate(original, operator: .byteInsert, rng: &rng)
        XCTAssertEqual(mutated.count, original.count + 1)
    }

    func test_mutate_byteDelete_shrinksByOne() {
        let original = Data(repeating: 0xAA, count: 32)
        var rng = PropertyTest.SeededRNG(seed: 11)
        let mutated = FuzzHarness.mutate(original, operator: .byteDelete, rng: &rng)
        XCTAssertEqual(mutated.count, original.count - 1)
    }

    func test_mutate_truncate_shortens() {
        let original = Data(repeating: 0xAA, count: 32)
        var rng = PropertyTest.SeededRNG(seed: 13)
        let mutated = FuzzHarness.mutate(original, operator: .truncate, rng: &rng)
        XCTAssertLessThan(mutated.count, original.count)
    }

    func test_run_iteratesNTimes() {
        var seen = 0
        FuzzHarness.run(
            target: Data(repeating: 0, count: 16),
            iterations: 100,
            seed: 42,
            operators: [.bitFlip, .byteInsert, .byteDelete, .truncate]
        ) { _ in
            seen += 1
        }
        XCTAssertEqual(seen, 100)
    }
}
