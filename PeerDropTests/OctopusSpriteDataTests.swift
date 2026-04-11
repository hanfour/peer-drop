import XCTest
@testable import PeerDrop

final class OctopusSpriteDataTests: XCTestCase {
    private let requiredActions: [PetAction] = [
        .idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
        .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
        .love, .tapReact, .pickedUp, .thrown, .petted
    ]

    func testOctopusBabyHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(OctopusSpriteData.baby[action], "Missing octopus baby sprite for \(action)")
        }
    }

    func testOctopusChildHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(OctopusSpriteData.child[action], "Missing octopus child sprite for \(action)")
        }
    }

    func testOctopusBabyFramesAre16x16() {
        for (action, frames) in OctopusSpriteData.baby {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "baby \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "baby \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testOctopusChildFramesAre16x16() {
        for (action, frames) in OctopusSpriteData.child {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "child \(action) frame \(i) rows")
                for (row, pixels) in frame.enumerated() {
                    XCTAssertEqual(pixels.count, 16, "child \(action) frame \(i) row \(row) cols")
                }
            }
        }
    }

    func testOctopusMetaInBounds() {
        let meta = OctopusSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }
}
