import XCTest
@testable import PeerDrop

final class SpriteCompositorTests: XCTestCase {

    func testCompositeBodyOnly() {
        let body: [[UInt8]] = Array(repeating: Array(repeating: 2, count: 16), count: 16)
        let result = SpriteCompositor.composite(body: body, eyes: nil, eyeAnchor: nil, pattern: nil, patternMask: nil)
        XCTAssertEqual(result.count, 16)
        XCTAssertEqual(result[0][0], 2)
    }

    func testCompositeOverlaysEyes() {
        let body: [[UInt8]] = Array(repeating: Array(repeating: 2, count: 16), count: 16)
        let eyes: [[UInt8]] = [[5, 0, 0, 5]]
        let anchor = (x: 4, y: 4)
        let result = SpriteCompositor.composite(body: body, eyes: eyes, eyeAnchor: anchor, pattern: nil, patternMask: nil)
        XCTAssertEqual(result[4][4], 5)
        XCTAssertEqual(result[4][5], 2)
        XCTAssertEqual(result[4][7], 5)
    }

    func testCompositeAppliesPattern() {
        let body: [[UInt8]] = Array(repeating: Array(repeating: 2, count: 16), count: 16)
        let pattern: [[UInt8]] = [[6, 0, 6, 0]]
        let mask: [[Bool]] = Array(repeating: Array(repeating: true, count: 16), count: 16)
        let result = SpriteCompositor.composite(body: body, eyes: nil, eyeAnchor: nil,
                                                  pattern: pattern, patternMask: mask)
        XCTAssertEqual(result[0][0], 6)
        XCTAssertEqual(result[0][1], 2)
    }

    func testFlipHorizontal() {
        let indices: [[UInt8]] = [[1, 0, 0, 2]]
        let flipped = SpriteCompositor.flipHorizontal(indices)
        XCTAssertEqual(flipped, [[2, 0, 0, 1]])
    }
}
