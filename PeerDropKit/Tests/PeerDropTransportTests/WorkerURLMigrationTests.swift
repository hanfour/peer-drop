import XCTest
@testable import PeerDropTransport

final class WorkerURLMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() { suite = "test.workerurl.\(UUID().uuidString)"; defaults = UserDefaults(suiteName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testCurrentFallsBackToProduction() {
        XCTAssertEqual(WorkerURL.current(defaults: defaults), WorkerURL.production)
    }
    func testMigrateMovesLegacyKeyWhenNewKeyUnset() {
        defaults.set("https://staging.example.com", forKey: WorkerURL.legacyDefaultsKey)
        WorkerURL.migrateLegacyKey(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: WorkerURL.defaultsKey), "https://staging.example.com")
        XCTAssertNil(defaults.string(forKey: WorkerURL.legacyDefaultsKey))
        XCTAssertEqual(WorkerURL.current(defaults: defaults).absoluteString, "https://staging.example.com")
    }
    func testMigrateKeepsNewKeyWhenBothSet() {
        defaults.set("https://new.example.com", forKey: WorkerURL.defaultsKey)
        defaults.set("https://old.example.com", forKey: WorkerURL.legacyDefaultsKey)
        WorkerURL.migrateLegacyKey(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: WorkerURL.defaultsKey), "https://new.example.com")
        XCTAssertNil(defaults.string(forKey: WorkerURL.legacyDefaultsKey))
    }
}
