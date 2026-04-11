import XCTest
@testable import PeerDrop

final class GhostSpriteDataTests: XCTestCase {
    private let requiredActions: [PetAction] = [
        .idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
        .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
        .love, .tapReact, .pickedUp, .thrown, .petted
    ]

    func testGhostBabyHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(GhostSpriteData.baby[action], "Missing ghost baby sprite for \(action)")
        }
    }

    func testGhostChildHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(GhostSpriteData.child[action], "Missing ghost child sprite for \(action)")
        }
    }

    func testGhostBabyFramesAre16x16() {
        for (action, frames) in GhostSpriteData.baby {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "baby \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "baby \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testGhostChildFramesAre16x16() {
        for (action, frames) in GhostSpriteData.child {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "child \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "child \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testGhostMetaInBounds() {
        let meta = GhostSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }
}
