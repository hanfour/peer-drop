import XCTest
@testable import PeerDrop

final class BirdSpriteDataTests: XCTestCase {
    private let requiredActions: [PetAction] = [
        .idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
        .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
        .love, .tapReact, .pickedUp, .thrown, .petted
    ]

    func testBirdBabyHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(BirdSpriteData.baby[action], "Missing bird baby sprite for \(action)")
        }
    }

    func testBirdChildHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(BirdSpriteData.child[action], "Missing bird child sprite for \(action)")
        }
    }

    func testBirdBabyFramesAre16x16() {
        for (action, frames) in BirdSpriteData.baby {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "baby \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "baby \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testBirdChildFramesAre16x16() {
        for (action, frames) in BirdSpriteData.child {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "child \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "child \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testBirdMetaInBounds() {
        let meta = BirdSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }
}
