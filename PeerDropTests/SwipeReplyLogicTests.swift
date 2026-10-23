import XCTest
@testable import PeerDrop

final class SwipeReplyLogicTests: XCTestCase {
    func testHorizontalDominance() {
        XCTAssertTrue(SwipeReplyLogic.isHorizontalDominant(dx: 40, dy: 5))
        XCTAssertTrue(SwipeReplyLogic.isHorizontalDominant(dx: -40, dy: 5))
        XCTAssertFalse(SwipeReplyLogic.isHorizontalDominant(dx: 10, dy: 30))
        XCTAssertFalse(SwipeReplyLogic.isHorizontalDominant(dx: 30, dy: 30))
        XCTAssertFalse(SwipeReplyLogic.isHorizontalDominant(dx: 40, dy: 30))
        XCTAssertFalse(SwipeReplyLogic.isHorizontalDominant(dx: 45, dy: 30)) // strict > 1.5
    }

    func testLeftwardOrZeroIsInert() {
        for w: CGFloat in [0, -1, -50, -10_000] {
            XCTAssertEqual(SwipeReplyLogic.rowOffset(forTranslationWidth: w), 0)
            XCTAssertEqual(SwipeReplyLogic.progress(forTranslationWidth: w), 0)
            XCTAssertFalse(SwipeReplyLogic.shouldTrigger(translationWidth: w, isHorizontal: true, isDeleted: false))
        }
    }

    func testOffsetMonotonicAndBounded() {
        var last: CGFloat = 0
        for w in stride(from: CGFloat(0), through: 400, by: 5) {
            let o = SwipeReplyLogic.rowOffset(forTranslationWidth: w)
            XCTAssertGreaterThanOrEqual(o, last)
            XCTAssertLessThanOrEqual(o, SwipeReplyLogic.maxOffset)
            last = o
        }
        XCTAssertLessThanOrEqual(SwipeReplyLogic.rowOffset(forTranslationWidth: 10_000), SwipeReplyLogic.maxOffset)
        XCTAssertGreaterThan(SwipeReplyLogic.rowOffset(forTranslationWidth: 20), 0)
    }

    func testProgress() {
        XCTAssertEqual(SwipeReplyLogic.progress(forTranslationWidth: SwipeReplyLogic.threshold), 1)
        XCTAssertEqual(SwipeReplyLogic.progress(forTranslationWidth: 500), 1)
        XCTAssertEqual(SwipeReplyLogic.progress(forTranslationWidth: 30), 0.5, accuracy: 0.0001)
        for w in stride(from: CGFloat(-20), through: 200, by: 7) {
            let p = SwipeReplyLogic.progress(forTranslationWidth: w)
            XCTAssertTrue((0...1).contains(p))
        }
    }

    func testShouldTrigger() {
        XCTAssertTrue(SwipeReplyLogic.shouldTrigger(translationWidth: 60, isHorizontal: true, isDeleted: false))
        XCTAssertFalse(SwipeReplyLogic.shouldTrigger(translationWidth: 59.9, isHorizontal: true, isDeleted: false))
        XCTAssertFalse(SwipeReplyLogic.shouldTrigger(translationWidth: 500, isHorizontal: false, isDeleted: false))
        XCTAssertFalse(SwipeReplyLogic.shouldTrigger(translationWidth: 500, isHorizontal: true, isDeleted: true))
    }

    func testDecideAxis() {
        // Undecided below the radius.
        XCTAssertNil(SwipeReplyLogic.decideAxis(current: nil, dx: 5, dy: 3))
        // Decided at the radius.
        XCTAssertEqual(SwipeReplyLogic.decideAxis(current: nil, dx: 12, dy: 0), true)
        XCTAssertEqual(SwipeReplyLogic.decideAxis(current: nil, dx: 2, dy: 12), false)
        // Never flipped by later wobble.
        XCTAssertEqual(SwipeReplyLogic.decideAxis(current: true, dx: 1, dy: 100), true)
        XCTAssertEqual(SwipeReplyLogic.decideAxis(current: false, dx: 100, dy: 1), false)
        // A fresh drag re-decides.
        XCTAssertEqual(SwipeReplyLogic.decideAxis(current: nil, dx: 1, dy: 100), false)
    }
}
