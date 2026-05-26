// PeerDropKit/Tests/PeerDropPetTests/PeerDropPetTests.swift
import XCTest
@testable import PeerDropPet

final class PeerDropPetTests: XCTestCase {
    /// Placeholder. Real tests for PeerDropPet consumers (PetGenome, SpeciesCatalog, PetRendererV3, sprite atlas) migrate
    /// here in M1d-2 alongside the source files. This single trivial test
    /// ensures `swift test` can find + run a test target.
    func test_moduleIsLinkable() {
        // PeerDropPet is currently `public enum PeerDropPet {}` — verify
        // the test target can reference it.
        XCTAssertNotNil(PeerDropPet.self)
    }
}
