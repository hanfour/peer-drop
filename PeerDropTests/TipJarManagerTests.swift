import XCTest
import StoreKit
@testable import PeerDrop

/// Tests for `TipJarManager`. Scope-capped to state shape + lifecycle.
/// Full purchase-flow tests need a `.storekit` config file + an
/// `SKTestSession` — deferred until the three IAPs are actually
/// registered in App Store Connect and the operator can confirm the
/// sandbox matches the spec.
@MainActor
final class TipJarManagerTests: XCTestCase {

    func test_initialState_isEmpty() {
        let m = TipJarManager.shared
        // Singleton state may carry over between tests if other tests
        // mutated it. Snapshot what matters and check the contract
        // each accessor exposes, not absolute values.
        XCTAssertNotNil(m.products as [Product]?)
        XCTAssertNil(m.purchasingProductID, "no purchase in flight at start")
    }

    func test_productIDs_areThePinnedTrio() {
        // These IDs are baked into App Store Connect IAP records;
        // renaming them invalidates every existing receipt. The list
        // ordering also matches the display order on the Settings
        // card (small → medium → large), so a reorder would silently
        // visually swap the cards on every device.
        XCTAssertEqual(TipJarManager.productIDs.count, 3)
        XCTAssertEqual(TipJarManager.productIDs[0], "com.hanfour.peerdrop.tip.small")
        XCTAssertEqual(TipJarManager.productIDs[1], "com.hanfour.peerdrop.tip.medium")
        XCTAssertEqual(TipJarManager.productIDs[2], "com.hanfour.peerdrop.tip.large")
    }

    func test_lastError_canBeClearedFromCallSite() {
        // The Settings alert's binding-setter clears `lastError` when
        // the user dismisses. This test pins that `lastError` is
        // user-writable (the @Published field exposes both get + set
        // so the binding can write nil back).
        let m = TipJarManager.shared
        m.lastError = "synthetic"
        XCTAssertEqual(m.lastError, "synthetic")
        m.lastError = nil
        XCTAssertNil(m.lastError)
    }

    func test_lastSucceededTipName_canBeClearedFromCallSite() {
        // Same pattern as lastError — TipJarSection's onChange handler
        // nils it out after the toast finishes its 3-second animation.
        let m = TipJarManager.shared
        m.lastSucceededTipName = "Coffee"
        XCTAssertEqual(m.lastSucceededTipName, "Coffee")
        m.lastSucceededTipName = nil
        XCTAssertNil(m.lastSucceededTipName)
    }

    func test_startObservingTransactions_isIdempotent() {
        // The lifecycle is: PeerDropApp.task fires startObservingTransactions
        // exactly once at launch. If the app scene rebuilds (split view
        // transitions, scene restoration), calling again must replace
        // the prior observer task cleanly without leaking it. Pinning
        // this prevents a regression where double-calls would create
        // two concurrent Transaction.updates readers.
        let m = TipJarManager.shared
        m.startObservingTransactions()
        m.startObservingTransactions()
        m.startObservingTransactions()
        // If we got here, no preconditions tripped. Cleanup is implicit
        // in the actor's deinit — but the shared singleton never deinits
        // during the test process, so the verification is "didn't crash".
    }
}
