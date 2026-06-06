import XCTest
@testable import PeerDropPlatform

final class PlatformIdentifierTests: XCTestCase {
    func test_defaultIdentifier_resolvesToCurrentPlatform() {
        let identifier = PlatformDependencies.shared.platformIdentifier()
        #if canImport(UIKit)
        XCTAssertEqual(identifier, "ios")
        #elseif os(macOS)
        XCTAssertEqual(identifier, "macos")
        #else
        XCTFail("Unsupported test platform")
        #endif
    }

    func test_injectedIdentifier_overridesDefault() {
        // PlatformDependencies.shared is a mutable singleton; preserve
        // the original closure so concurrent / sequenced tests aren't
        // polluted by this override.
        let original = PlatformDependencies.shared.platformIdentifier
        PlatformDependencies.shared.platformIdentifier = { "test-platform" }
        defer { PlatformDependencies.shared.platformIdentifier = original }

        XCTAssertEqual(PlatformDependencies.shared.platformIdentifier(), "test-platform")
    }
}
