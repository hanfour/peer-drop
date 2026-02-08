import XCTest
@testable import PeerDrop

final class RetryPolicyTests: XCTestCase {

    // MARK: - ExponentialBackoff Tests

    func testDefaultBackoffConfiguration() {
        let backoff = ExponentialBackoff.default
        XCTAssertEqual(backoff.initialDelay, 1.0)
        XCTAssertEqual(backoff.maxDelay, 30.0)
        XCTAssertEqual(backoff.multiplier, 2.0)
        XCTAssertEqual(backoff.maxAttempts, 5)
    }

    func testDelayIncreasesExponentially() {
        let backoff = ExponentialBackoff(
            initialDelay: 1.0,
            maxDelay: 100.0,
            multiplier: 2.0,
            maxAttempts: 10
        )

        // Without jitter, delays would be: 1, 2, 4, 8, 16...
        // With jitter (0.9-1.1), we check ranges
        let delay0 = backoff.delay(for: 0)
        let delay1 = backoff.delay(for: 1)
        let delay2 = backoff.delay(for: 2)
        let delay3 = backoff.delay(for: 3)

        // Check approximate ranges (accounting for jitter)
        XCTAssertTrue(delay0 >= 0.9 && delay0 <= 1.1, "Attempt 0 delay should be ~1s")
        XCTAssertTrue(delay1 >= 1.8 && delay1 <= 2.2, "Attempt 1 delay should be ~2s")
        XCTAssertTrue(delay2 >= 3.6 && delay2 <= 4.4, "Attempt 2 delay should be ~4s")
        XCTAssertTrue(delay3 >= 7.2 && delay3 <= 8.8, "Attempt 3 delay should be ~8s")
    }

    func testDelayNeverExceedsMax() {
        let backoff = ExponentialBackoff(
            initialDelay: 1.0,
            maxDelay: 10.0,
            multiplier: 2.0,
            maxAttempts: 20
        )

        // After several attempts, delay should cap at maxDelay
        for attempt in 0..<20 {
            let delay = backoff.delay(for: attempt)
            XCTAssertLessThanOrEqual(delay, 10.0 * 1.1, "Delay should never exceed max (with jitter)")
        }
    }

    func testCanRetryWithinLimit() {
        let backoff = ExponentialBackoff(
            initialDelay: 1.0,
            maxDelay: 30.0,
            multiplier: 2.0,
            maxAttempts: 5
        )

        XCTAssertTrue(backoff.canRetry(0))
        XCTAssertTrue(backoff.canRetry(1))
        XCTAssertTrue(backoff.canRetry(4))
        XCTAssertFalse(backoff.canRetry(5))
        XCTAssertFalse(backoff.canRetry(10))
    }

    func testDelayAtMaxAttemptsReturnsMaxDelay() {
        let backoff = ExponentialBackoff(
            initialDelay: 1.0,
            maxDelay: 30.0,
            multiplier: 2.0,
            maxAttempts: 3
        )

        // Beyond max attempts, should return maxDelay
        let delay = backoff.delay(for: 10)
        XCTAssertEqual(delay, 30.0)
    }

    // MARK: - RetryController Tests

    func testRetryControllerInitialState() async {
        let controller = RetryController()
        let attempt = await controller.currentAttempt
        XCTAssertEqual(attempt, 0)
    }

    func testRetryControllerNextDelayIncrementsAttempt() async {
        let controller = RetryController()

        let delay1 = await controller.nextDelay()
        XCTAssertNotNil(delay1)
        let attempt1 = await controller.currentAttempt
        XCTAssertEqual(attempt1, 1)

        let delay2 = await controller.nextDelay()
        XCTAssertNotNil(delay2)
        let attempt2 = await controller.currentAttempt
        XCTAssertEqual(attempt2, 2)
    }

    func testRetryControllerReturnsNilWhenExhausted() async {
        let policy = ExponentialBackoff(
            initialDelay: 1.0,
            maxDelay: 10.0,
            multiplier: 2.0,
            maxAttempts: 3
        )
        let controller = RetryController(policy: policy)

        // Use up all attempts
        _ = await controller.nextDelay() // attempt 0
        _ = await controller.nextDelay() // attempt 1
        _ = await controller.nextDelay() // attempt 2

        // Should return nil now
        let exhausted = await controller.nextDelay()
        XCTAssertNil(exhausted, "Should return nil when max attempts exhausted")
    }

    func testRetryControllerReset() async {
        let controller = RetryController()

        // Use some attempts
        _ = await controller.nextDelay()
        _ = await controller.nextDelay()
        let beforeReset = await controller.currentAttempt
        XCTAssertEqual(beforeReset, 2)

        // Reset
        await controller.reset()
        let afterReset = await controller.currentAttempt
        XCTAssertEqual(afterReset, 0)

        // Should be able to get delays again
        let delayAfterReset = await controller.nextDelay()
        XCTAssertNotNil(delayAfterReset)
    }

    func testRetryControllerDelaysIncrease() async {
        let policy = ExponentialBackoff(
            initialDelay: 1.0,
            maxDelay: 100.0,
            multiplier: 2.0,
            maxAttempts: 5
        )
        let controller = RetryController(policy: policy)

        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            if let delay = await controller.nextDelay() {
                delays.append(delay)
            }
        }

        XCTAssertEqual(delays.count, 4)
        // Each delay should be roughly double the previous (within jitter range)
        for i in 1..<delays.count {
            let ratio = delays[i] / delays[i-1]
            XCTAssertTrue(ratio > 1.5 && ratio < 2.5, "Delay ratio should be approximately 2x")
        }
    }
}
