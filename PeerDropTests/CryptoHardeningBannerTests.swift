import XCTest
import SwiftUI
@testable import PeerDrop

final class CryptoHardeningBannerTests: XCTestCase {

    func test_init_setsKindAndAction() {
        var fired = false
        let view = CryptoHardeningBanner(
            kind: .c2OPKRetry(attempts: 2, max: 5),
            onPrimaryAction: { fired = true }
        )
        if case .c2OPKRetry(let a, let m) = view.kind {
            XCTAssertEqual(a, 2)
            XCTAssertEqual(m, 5)
        } else {
            XCTFail("expected .c2OPKRetry")
        }
        view.invokeActionForTesting()
        XCTAssertTrue(fired)
    }

    func test_exhaustedKind_invokesActionWhenRetried() {
        var attempts = 0
        let view = CryptoHardeningBanner(
            kind: .c2OPKExhausted,
            onPrimaryAction: { attempts += 1 }
        )
        view.invokeActionForTesting()
        view.invokeActionForTesting()
        XCTAssertEqual(attempts, 2)
    }

    func test_kindEquatable() {
        let a: CryptoHardeningBanner.Kind = .c2OPKRetry(attempts: 1, max: 5)
        let b: CryptoHardeningBanner.Kind = .c2OPKRetry(attempts: 1, max: 5)
        let c: CryptoHardeningBanner.Kind = .c2OPKRetry(attempts: 2, max: 5)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, .c2OPKExhausted)
    }

    func test_c1SPKExpired_kind_setsActionAndIsEquatable() {
        var fired = false
        let view = CryptoHardeningBanner(
            kind: .c1SPKExpired,
            onPrimaryAction: { fired = true }
        )
        XCTAssertEqual(view.kind, .c1SPKExpired)
        view.invokeActionForTesting()
        XCTAssertTrue(fired)
    }

    func test_c1SPKExpired_kindEquatable() {
        XCTAssertEqual(CryptoHardeningBanner.Kind.c1SPKExpired, .c1SPKExpired)
        XCTAssertNotEqual(CryptoHardeningBanner.Kind.c1SPKExpired, .c2OPKExhausted)
    }
}
