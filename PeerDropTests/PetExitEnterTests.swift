import XCTest
@testable import PeerDrop

final class PetExitEnterTests: XCTestCase {
    func testCatExitHasScaleStep() {
        let cat = CatBehavior()
        let seq = cat.exitSequence(from: CGPoint(x: 200, y: 700),
                                    screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertFalse(seq.steps.isEmpty)
        let hasScale = seq.steps.contains { $0.scaleDelta != nil }
        XCTAssertTrue(hasScale, "Cat exit should include scale change for perspective walk")
    }

    func testDogExitStartsWithDig() {
        let dog = DogBehavior()
        let seq = dog.exitSequence(from: CGPoint(x: 200, y: 700),
                                    screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertEqual(seq.steps.first?.action, .dig)
    }

    func testBirdExitIsGlide() {
        let bird = BirdBehavior()
        let seq = bird.exitSequence(from: CGPoint(x: 200, y: 300),
                                     screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertEqual(seq.steps.first?.action, .glide)
    }


    func testSlimeExitIsMelt() {
        let slime = SlimeBehavior()
        let seq = slime.exitSequence(from: CGPoint(x: 200, y: 700),
                                      screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertEqual(seq.steps.first?.action, .melt)
    }

    func testAllEnterSequencesNotEmpty() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        for body in BodyGene.allCases {
            let provider = PetBehaviorProviderFactory.create(for: body)
            let seq = provider.enterSequence(screenBounds: bounds)
            XCTAssertFalse(seq.steps.isEmpty, "\(body) enter sequence should not be empty")
        }
    }

    func testAllExitSequencesNotEmpty() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        for body in BodyGene.allCases {
            let provider = PetBehaviorProviderFactory.create(for: body)
            let seq = provider.exitSequence(from: CGPoint(x: 200, y: 700), screenBounds: bounds)
            XCTAssertFalse(seq.steps.isEmpty, "\(body) exit sequence should not be empty")
        }
    }
}
