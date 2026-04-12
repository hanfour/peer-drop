import XCTest
@testable import PeerDrop

final class DogSpriteDataTests: XCTestCase {
    private let requiredActions: [PetAction] = [
        .idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
        .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
        .love, .tapReact, .pickedUp, .thrown, .petted
    ]

    func testDogBabyHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(DogSpriteData.baby[action], "Missing dog baby sprite for \(action)")
        }
    }

    func testDogChildHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(DogSpriteData.child[action], "Missing dog child sprite for \(action)")
        }
    }

    func testDogBabyFramesAre16x16() {
        for (action, frames) in DogSpriteData.baby {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "baby \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "baby \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testDogChildFramesAre16x16() {
        for (action, frames) in DogSpriteData.child {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "child \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "child \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testDogMetaInBounds() {
        let meta = DogSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }
}
