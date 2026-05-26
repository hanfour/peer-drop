import XCTest
@testable import PeerDropSecurity

final class TestVectorLoaderTests: XCTestCase {
    struct Sample: Codable, Equatable {
        let name: String
        let value: Int
    }

    func test_loadsAndParsesJSON() throws {
        let url = Bundle.module.url(
            forResource: "example-loader-test",
            withExtension: "json",
            subdirectory: "Resources"
        )
        guard let url = url else {
            return XCTFail("example-loader-test.json not in test bundle — project.yml may need an explicit resource path under PeerDropTests target. See task notes.")
        }
        let v: Sample = try TestVectorLoader.load(from: url)
        XCTAssertEqual(v, Sample(name: "test", value: 42))
    }
}
