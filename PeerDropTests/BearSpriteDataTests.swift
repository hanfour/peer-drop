import XCTest
@testable import PeerDrop

final class BearSpriteDataTests: XCTestCase {
    private let requiredActions: [PetAction] = [
        .idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
        .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
        .love, .tapReact, .pickedUp, .thrown, .petted
    ]

    func testBearBabyHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(BearSpriteData.baby[action], "Missing bear baby sprite for \(action)")
        }
    }

    func testBearChildHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(BearSpriteData.child[action], "Missing bear child sprite for \(action)")
        }
    }

    func testBearBabyFramesAre16x16() {
        for (action, frames) in BearSpriteData.baby {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "baby \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "baby \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testBearChildFramesAre16x16() {
        for (action, frames) in BearSpriteData.child {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "child \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "child \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testBearMetaInBounds() {
        let meta = BearSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }
}
