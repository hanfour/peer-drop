import XCTest
@testable import PeerDrop

final class PetSnapshotRendererTests: XCTestCase {
    func testRenderCatBaby16x16() {
        let image = PetSnapshotRenderer.render(
            body: .cat, level: .baby, mood: .happy,
            eyes: .dot, pattern: .none, paletteIndex: 0, scale: 1)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 16)
    }

    func testRenderEgg() {
        let image = PetSnapshotRenderer.render(
            body: .cat, level: .egg, mood: .curious,
            eyes: .dot, pattern: .none, paletteIndex: 0, scale: 1)
        XCTAssertNotNil(image)
    }

    func testRenderScaled128() {
        let image = PetSnapshotRenderer.render(
            body: .dog, level: .child, mood: .sleepy,
            eyes: .round, pattern: .stripe, paletteIndex: 3, scale: 8)
        XCTAssertEqual(image?.width, 128)
    }

    func testIslandPoseMapping() {
        XCTAssertEqual(IslandPose.from(mood: .sleepy), .sleeping)
        XCTAssertEqual(IslandPose.from(mood: .happy), .happy)
        XCTAssertEqual(IslandPose.from(mood: .lonely), .lonely)
        XCTAssertEqual(IslandPose.from(mood: .curious), .sitting)
    }
}
