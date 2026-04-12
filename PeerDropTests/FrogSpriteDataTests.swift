import XCTest
@testable import PeerDrop

final class FrogSpriteDataTests: XCTestCase {
    private let requiredActions: [PetAction] = [
        .idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
        .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
        .love, .tapReact, .pickedUp, .thrown, .petted
    ]

    func testFrogBabyHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(FrogSpriteData.baby[action], "Missing frog baby sprite for \(action)")
        }
    }

    func testFrogChildHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(FrogSpriteData.child[action], "Missing frog child sprite for \(action)")
        }
    }

    func testFrogBabyFramesAre16x16() {
        for (action, frames) in FrogSpriteData.baby {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "baby \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "baby \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testFrogChildFramesAre16x16() {
        for (action, frames) in FrogSpriteData.child {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "child \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "child \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testFrogMetaInBounds() {
        let meta = FrogSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }
}
