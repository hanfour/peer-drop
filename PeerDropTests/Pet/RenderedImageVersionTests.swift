import XCTest
@testable import PeerDrop

/// Tests for the Phase 6 widget bridge invalidation flag.
///
/// Persistence behavior: `UserDefaults.standard` carries a string under
/// `renderedImageVersion` that mirrors the renderer's current contract
/// version. On launch, PeerDropApp reads this; if it doesn't match the
/// current version (`"v5"` for this release), it triggers one fresh render
/// before stamping the new value. Logic is gated by the value comparison
/// itself — there's no separate "did-rerender" state, so a downgrade
/// (v5 -> v4) would correctly re-trigger if we ever shipped that.
final class RenderedImageVersionTests: XCTestCase {

    private let key = "renderedImageVersion"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "rendered-version-tests-\(UUID().uuidString)")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation()["__suiteName__"] as? String ?? "")
        defaults = nil
        super.tearDown()
    }

    func test_versionFlag_emptyByDefault() {
        XCTAssertNil(defaults.string(forKey: key))
    }

    func test_versionFlag_persistsAcrossReads() {
        defaults.set("v5", forKey: key)
        XCTAssertEqual(defaults.string(forKey: key), "v5")
    }

    func test_versionFlag_v4ToV5_transitionTriggersRerender() {
        // Pre-condition: device was on v4
        defaults.set("v4", forKey: key)
        // Decision logic mirrors PeerDropApp:
        let needsRerender = (defaults.string(forKey: key) ?? "") != "v5"
        XCTAssertTrue(needsRerender, "v4 -> v5 must trigger rerender")
    }

    func test_versionFlag_freshDevice_transitionTriggersRerender() {
        // Pre-condition: never set (fresh install — first launch on v5)
        let needsRerender = (defaults.string(forKey: key) ?? "") != "v5"
        XCTAssertTrue(needsRerender, "fresh install must trigger initial render")
    }

    func test_versionFlag_alreadyV5_skipsRerender() {
        defaults.set("v5", forKey: key)
        let needsRerender = (defaults.string(forKey: key) ?? "") != "v5"
        XCTAssertFalse(needsRerender, "v5 -> v5 must not re-fire")
    }
}
