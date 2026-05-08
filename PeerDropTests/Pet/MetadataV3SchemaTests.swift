import XCTest
@testable import PeerDrop

final class MetadataV3SchemaTests: XCTestCase {

    private var testBundle: Bundle { Bundle(for: type(of: self)) }

    func test_parseV3Metadata_returnsAnimationDescriptors() throws {
        let url = testBundle.url(
            forResource: "test-anim-v3",
            withExtension: "zip",
            subdirectory: "Pets"
        )!
        let metadata = try SpriteMetadata.parse(zipURL: url)

        XCTAssertEqual(metadata.exportVersion, "3.0")

        let walk = try XCTUnwrap(metadata.animations["walk"])
        XCTAssertEqual(walk.fps, 6)
        XCTAssertEqual(walk.frameCount, 8)
        XCTAssertTrue(walk.loops)
        XCTAssertEqual(walk.directions["south"]?.count, 8)

        let idle = try XCTUnwrap(metadata.animations["idle"])
        XCTAssertEqual(idle.fps, 2)
        XCTAssertEqual(idle.frameCount, 4)
        XCTAssertTrue(idle.loops)
        XCTAssertEqual(idle.directions["south"]?.count, 4)
    }

    func test_parseV2Metadata_returnsEmptyAnimations() throws {
        let url = testBundle.url(
            forResource: "cat-tabby-adult",
            withExtension: "zip",
            subdirectory: "Pets"
        )!
        let metadata = try SpriteMetadata.parse(zipURL: url)

        XCTAssertEqual(metadata.exportVersion, "2.0")
        XCTAssertTrue(metadata.animations.isEmpty)
    }
}
