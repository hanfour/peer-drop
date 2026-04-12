import XCTest
@testable import PeerDrop

final class SlimeSpriteDataTests: XCTestCase {
    private let requiredActions: [PetAction] = [
        .idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
        .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
        .love, .tapReact, .pickedUp, .thrown, .petted
    ]

    func testSlimeBabyHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(SlimeSpriteData.baby[action], "Missing slime baby sprite for \(action)")
        }
    }

    func testSlimeChildHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(SlimeSpriteData.child[action], "Missing slime child sprite for \(action)")
        }
    }

    func testSlimeBabyFramesAre16x16() {
        for (action, frames) in SlimeSpriteData.baby {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "baby \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "baby \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testSlimeChildFramesAre16x16() {
        for (action, frames) in SlimeSpriteData.child {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "child \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "child \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testSlimeMetaInBounds() {
        let meta = SlimeSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }
}
