import XCTest
@testable import PeerDrop

final class PetSpriteTemplatesTests: XCTestCase {

    // MARK: - Egg templates

    func testEggTemplateHasTwoFrames() {
        XCTAssertEqual(PetSpriteTemplates.egg.count, 2)
    }

    func testEggTemplatesAreNonEmpty() {
        for (i, frame) in PetSpriteTemplates.egg.enumerated() {
            let hasPixels = frame.pixels.flatMap { $0 }.contains(where: { $0 != 0 })
            XCTAssertTrue(hasPixels, "Egg frame \(i) should have non-zero pixels")
        }
    }

    func testEggCrackCoordinatesExist() {
        let egg = PetSpriteTemplates.egg[0]
        XCTAssertFalse(egg.crackLeftPixels.isEmpty)
        XCTAssertFalse(egg.crackRightPixels.isEmpty)
    }

    // MARK: - Body templates

    func testAllBodyTypesHaveTemplates() {
        for body in BodyGene.allCases {
            let templates = PetSpriteTemplates.body(for: body)
            XCTAssertEqual(templates.count, 2, "\(body) should have 2 frames")
            for (i, t) in templates.enumerated() {
                let hasPixels = t.pixels.flatMap { $0 }.contains(where: { $0 != 0 })
                XCTAssertTrue(hasPixels, "\(body) frame \(i) should have pixels")
            }
        }
    }

    func testBodyTemplatesHaveAnchors() {
        for body in BodyGene.allCases {
            let t = PetSpriteTemplates.body(for: body)[0]
            // Anchors should be within reasonable range (0-31)
            XCTAssertTrue(t.eyeAnchor.x >= 0 && t.eyeAnchor.x < 32)
            XCTAssertTrue(t.eyeAnchor.y >= 0 && t.eyeAnchor.y < 32)
            XCTAssertTrue(t.limbLeftAnchor.x >= -5 && t.limbLeftAnchor.x < 32)
            XCTAssertTrue(t.limbRightAnchor.x >= 0 && t.limbRightAnchor.x < 35)
        }
    }

    // MARK: - Eye templates

    func testAllEyeTypesHaveTemplates() {
        for eye in EyeGene.allCases {
            let template = PetSpriteTemplates.eyes(for: eye)
            let hasPixels = template.flatMap { $0 }.contains(where: { $0 != 0 })
            XCTAssertTrue(hasPixels, "\(eye) eyes should have pixels")
        }
    }

    func testMoodEyeOverrides() {
        let happy = PetSpriteTemplates.eyesMood(.happy)
        let sleepy = PetSpriteTemplates.eyesMood(.sleepy)
        let startled = PetSpriteTemplates.eyesMood(.startled)
        XCTAssertNotNil(happy)
        XCTAssertNotNil(sleepy)
        XCTAssertNotNil(startled)
        XCTAssertNil(PetSpriteTemplates.eyesMood(.curious)) // no override
    }

    // MARK: - Limb templates

    func testLimbTemplates() {
        let short = PetSpriteTemplates.limbs(for: .short, frame: 0)
        XCTAssertNotNil(short)
        let long = PetSpriteTemplates.limbs(for: .long, frame: 0)
        XCTAssertNotNil(long)
        let none = PetSpriteTemplates.limbs(for: .none, frame: 0)
        XCTAssertNil(none)
    }

    // MARK: - Pattern templates

    func testPatternTemplates() {
        XCTAssertNotNil(PetSpriteTemplates.pattern(for: .stripe))
        XCTAssertNotNil(PetSpriteTemplates.pattern(for: .spot))
        XCTAssertNil(PetSpriteTemplates.pattern(for: .none))
    }
}
