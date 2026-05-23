import XCTest
@testable import PeerDrop

final class PropertyTestHarnessTests: XCTestCase {
    func test_forAll_runsNTrials() {
        var calls = 0
        PropertyTest.forAll(trials: 50, seed: 42) { rng in
            calls += 1
            return true
        }
        XCTAssertEqual(calls, 50)
    }

    func test_forAll_fails_when_property_returns_false() {
        let result = PropertyTest.runCapturingFailure(trials: 100, seed: 42) { rng in
            return rng.next() % 10 != 7
        }
        XCTAssertNotNil(result.firstFailingSeed, "Expected at least one trial where rng.next() % 10 == 7")
    }

    func test_seededRNG_isDeterministic() {
        var a = PropertyTest.SeededRNG(seed: 1234)
        var b = PropertyTest.SeededRNG(seed: 1234)
        for _ in 0..<10 {
            XCTAssertEqual(a.next(), b.next(), "same seed → same sequence")
        }
    }
}
