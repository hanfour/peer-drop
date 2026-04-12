import XCTest
@testable import PeerDrop

final class RabbitSpriteDataTests: XCTestCase {
    private let requiredActions: [PetAction] = [
        .idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
        .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
        .love, .tapReact, .pickedUp, .thrown, .petted
    ]

    func testRabbitBabyHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(RabbitSpriteData.baby[action], "Missing rabbit baby sprite for \(action)")
        }
    }

    func testRabbitChildHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(RabbitSpriteData.child[action], "Missing rabbit child sprite for \(action)")
        }
    }

    func testRabbitBabyFramesAre16x16() {
        for (action, frames) in RabbitSpriteData.baby {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "baby \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "baby \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testRabbitChildFramesAre16x16() {
        for (action, frames) in RabbitSpriteData.child {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "child \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "child \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testRabbitMetaInBounds() {
        let meta = RabbitSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }
}
