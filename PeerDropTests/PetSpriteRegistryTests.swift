import XCTest
@testable import PeerDrop

final class PetSpriteRegistryTests: XCTestCase {
    func testSpeciesActionsFallbackToIdle() {
        let scratchFrames = SpriteDataRegistry.frameCount(for: .cat, stage: .baby, action: .scratch)
        let idleFrames = SpriteDataRegistry.frameCount(for: .cat, stage: .baby, action: .idle)
        XCTAssertGreaterThan(scratchFrames, 0, "Should fallback to idle frame count")
        XCTAssertEqual(scratchFrames, idleFrames, "Unknown action should fallback to idle")
    }

    func testAllBodiesHaveFallbackForNewActions() {
        let newActions: [PetAction] = [.scratch, .dig, .glide, .hover, .flicker, .melt]
        for body in BodyGene.allCases {
            for action in newActions {
                let frames = SpriteDataRegistry.frameCount(for: body, stage: .baby, action: action)
                XCTAssertGreaterThan(frames, 0, "\(body).\(action) should have fallback frameCount > 0")
            }
        }
    }

    func testResolvedActionFallsBackToIdle() {
        let resolved = SpriteDataRegistry.resolvedAction(for: .cat, stage: .baby, action: .scratch)
        XCTAssertEqual(resolved, .idle, "Unimplemented action should resolve to idle")
    }

    func testResolvedActionKeepsExisting() {
        let resolved = SpriteDataRegistry.resolvedAction(for: .cat, stage: .baby, action: .idle)
        XCTAssertEqual(resolved, .idle, "Existing action should stay as-is")
    }

    func testResolvedActionWalkExists() {
        let resolved = SpriteDataRegistry.resolvedAction(for: .cat, stage: .baby, action: .walking)
        // walking may or may not exist — just verify it doesn't crash
        XCTAssertTrue(resolved == .walking || resolved == .idle)
    }
}
