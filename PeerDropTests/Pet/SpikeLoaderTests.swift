import XCTest
@testable import PeerDrop

final class SpikeLoaderTests: XCTestCase {
    func test_loadEastFromCatTabbyAdult_returnsSquareCGImage() throws {
        let url = Bundle(for: type(of: self))
            .url(forResource: "cat-tabby-adult", withExtension: "zip")
        XCTAssertNotNil(url, "cat-tabby-adult.zip not bundled in test target")

        let cg = try SpikeLoader.loadEast(zipURL: url!)
        XCTAssertEqual(cg.width, 68)
        XCTAssertEqual(cg.height, 68)
    }
}
