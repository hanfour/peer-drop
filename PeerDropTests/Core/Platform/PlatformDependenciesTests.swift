// PeerDropTests/Core/Platform/PlatformDependenciesTests.swift
import XCTest
import PeerDropPlatform
@testable import PeerDrop

final class PlatformDependenciesTests: XCTestCase {
    func test_sharedIsMutable() {
        let original = PlatformDependencies.shared
        defer { PlatformDependencies.shared = original }

        PlatformDependencies.shared = PlatformDependencies()
        XCTAssertNotNil(PlatformDependencies.shared)
    }
}
