import XCTest
@testable import PeerDrop

final class DragonSpriteDataTests: XCTestCase {
    private let requiredActions: [PetAction] = [
        .idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
        .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
        .love, .tapReact, .pickedUp, .thrown, .petted
    ]

    func testDragonBabyHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(DragonSpriteData.baby[action], "Missing dragon baby sprite for \(action)")
        }
    }

    func testDragonChildHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(DragonSpriteData.child[action], "Missing dragon child sprite for \(action)")
        }
    }

    func testDragonBabyFramesAre16x16() {
        for (action, frames) in DragonSpriteData.baby {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "baby \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "baby \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testDragonChildFramesAre16x16() {
        for (action, frames) in DragonSpriteData.child {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "child \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "child \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testDragonMetaInBounds() {
        let meta = DragonSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }
}
