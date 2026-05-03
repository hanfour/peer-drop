import XCTest
@testable import PeerDrop

final class SpikeLoaderTests: XCTestCase {
    func test_loadEastFromCatTabbyAdult_returns68x68CGImage() throws {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "cat-tabby-adult",
                                            withExtension: "zip",
                                            subdirectory: "Pets"),
            "Pets/cat-tabby-adult.zip not bundled in test target"
        )
        let cg = try SpikeLoader.loadEast(zipURL: url)
        XCTAssertEqual(cg.width, 68)
        XCTAssertEqual(cg.height, 68)
    }
}
