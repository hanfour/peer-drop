import XCTest
@testable import PeerDrop

@MainActor
final class SpriteDataRegistryTests: XCTestCase {
    func testAllBodyTypesHaveBabySprites() {
        for body in BodyGene.allCases {
            let sprites = SpriteDataRegistry.sprites(for: body, stage: .baby)
            XCTAssertNotNil(sprites, "\(body) missing baby sprites")
            XCTAssertNotNil(sprites?[.idle], "\(body) baby missing idle")
        }
    }

    func testAllBodyTypesHaveAdultSprites() {
        for body in BodyGene.allCases {
            let sprites = SpriteDataRegistry.sprites(for: body, stage: .adult)
            XCTAssertNotNil(sprites, "\(body) missing adult sprites")
            XCTAssertNotNil(sprites?[.idle], "\(body) adult missing idle")
        }
    }

    func testAllBodyTypesHaveMeta() {
        for body in BodyGene.allCases {
            let meta = SpriteDataRegistry.meta(for: body)
            XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
            XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
        }
    }

    func testEggReturnsNilSprites() {
        XCTAssertNil(SpriteDataRegistry.sprites(for: .cat, stage: .egg))
    }

    func testFrameCountReturnsCorrectValue() {
        let count = SpriteDataRegistry.frameCount(for: .cat, stage: .baby, action: .idle)
        XCTAssertEqual(count, 4)
    }
}
