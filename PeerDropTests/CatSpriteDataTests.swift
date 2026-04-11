import XCTest
@testable import PeerDrop

final class CatSpriteDataTests: XCTestCase {

    func testCatIdleHas4Frames() {
        let frames = CatSpriteData.baby[.idle]!
        XCTAssertEqual(frames.count, 4)
        for frame in frames {
            XCTAssertEqual(frame.count, 16)
            XCTAssertEqual(frame[0].count, 16)
        }
    }

    func testCatWalkHas4Frames() {
        XCTAssertEqual(CatSpriteData.baby[.walking]!.count, 4)
    }

    func testCatHasAllRequiredActions() {
        let required: [PetAction] = [.idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
                                      .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
                                      .love, .tapReact, .pickedUp, .thrown, .petted]
        for action in required {
            XCTAssertNotNil(CatSpriteData.baby[action], "Missing cat baby sprite for \(action)")
        }
    }

    func testCatMetaAnchorsInBounds() {
        let meta = CatSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }

    func testEggIdleHas2Frames() {
        let frames = EggSpriteData.idle
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].count, 16)
        XCTAssertEqual(frames[0][0].count, 16)
    }

    func testEyeDotsExist() {
        let eyes = EyeSpriteData.sprites[.dot]!
        XCTAssertFalse(eyes.isEmpty)
    }

    func testAllFramesAre16x16() {
        for (action, frames) in CatSpriteData.baby {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "\(action) frame \(i) has \(frame.count) rows, expected 16")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "\(action) frame \(i) row \(row) has \(pixels.count) cols, expected 16")
                }
            }
        }
    }

    func testCatChildHasAllActions() {
        let required: [PetAction] = [.idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
                                      .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
                                      .love, .tapReact, .pickedUp, .thrown, .petted]
        for action in required {
            XCTAssertNotNil(CatSpriteData.child[action], "Missing cat child sprite for \(action)")
        }
    }

    func testCatChildFramesAre16x16() {
        for (action, frames) in CatSpriteData.child {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "child \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "child \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }
}
