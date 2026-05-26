import XCTest
@testable import PeerDropSecurity

@MainActor
final class SecurityPolicyStoreTests: XCTestCase {
    func test_init_with_no_cache_uses_bundled_default() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = SecurityPolicyStore(storageDirectory: tmpDir, publicKeys: [])
        XCTAssertEqual(store.current, .bundledDefault)
    }
}
