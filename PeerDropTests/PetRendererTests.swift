import XCTest
@testable import PeerDrop

final class PetRendererTests: XCTestCase {

    private let renderer = PetRenderer()

    private func makeGenome(
        body: BodyGene = .round,
        eyes: EyeGene = .dot,
        limbs: LimbGene = .short,
        pattern: PatternGene = .none,
        personality: Double = 0.5
    ) -> PetGenome {
        PetGenome(body: body, eyes: eyes, limbs: limbs, pattern: pattern, personalityGene: personality)
    }

    func testRenderEggProducesPixels() {
        let genome = makeGenome()
        let grid = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 0)
        XCTAssertTrue(grid.activePixelCount > 0, "Egg should produce visible pixels")
    }

    func testRenderBabyProducesMorePixelsThanEgg() {
        let genome = makeGenome()
        let egg = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 0)
        let baby = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        XCTAssertGreaterThan(baby.activePixelCount, egg.activePixelCount,
                             "Baby should have more pixels than egg")
    }

    func testDifferentGenomesProduceDifferentPixels() {
        let genome1 = makeGenome(body: .round, eyes: .dot, limbs: .short)
        let genome2 = makeGenome(body: .square, eyes: .dizzy, limbs: .long)
        let grid1 = renderer.render(genome: genome1, level: .baby, mood: .curious, animationFrame: 0)
        let grid2 = renderer.render(genome: genome2, level: .baby, mood: .curious, animationFrame: 0)
        XCTAssertNotEqual(grid1, grid2, "Different genomes should produce different pixel grids")
    }

    func testMoodAffectsEyes() {
        let genome = makeGenome()
        let happy = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        let sleepy = renderer.render(genome: genome, level: .baby, mood: .sleepy, animationFrame: 0)
        XCTAssertNotEqual(happy, sleepy, "Happy and sleepy moods should produce different grids")
    }

    func testEggBreathAnimation() {
        let genome = makeGenome()
        let frame0 = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 0)
        let frame1 = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 1)
        XCTAssertNotEqual(frame0, frame1, "Different frames should produce different egg shapes (breathing)")
    }

    func testEggCrackLinesAppearWithHighPersonality() {
        let lowPG = makeGenome(personality: 0.1)
        let highPG = makeGenome(personality: 0.8)
        let gridLow = renderer.render(genome: lowPG, level: .egg, mood: .happy, animationFrame: 0)
        let gridHigh = renderer.render(genome: highPG, level: .egg, mood: .happy, animationFrame: 0)
        // High personality gene should have more pixels due to crack lines
        XCTAssertGreaterThan(gridHigh.activePixelCount, gridLow.activePixelCount,
                             "Higher personality gene should add crack lines to the egg")
    }

    func testStartledMoodProducesDifferentGrid() {
        // Sleepy adds ZZZ pixels outside the body area, so it differs from startled
        let genome = makeGenome(eyes: .dot)
        let sleepy = renderer.render(genome: genome, level: .baby, mood: .sleepy, animationFrame: 0)
        let startled = renderer.render(genome: genome, level: .baby, mood: .startled, animationFrame: 0)
        XCTAssertNotEqual(sleepy, startled,
                          "Startled and sleepy moods should produce different grids")
    }

    func testAllBodyTypesRender() {
        for body in BodyGene.allCases {
            let genome = makeGenome(body: body)
            let grid = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
            XCTAssertTrue(grid.activePixelCount > 0, "Body type \(body) should produce pixels")
        }
    }

    func testAllLimbTypesRender() {
        for limb in LimbGene.allCases {
            let genome = makeGenome(limbs: limb)
            let grid = renderer.render(genome: genome, level: .baby, mood: .curious, animationFrame: 0)
            XCTAssertTrue(grid.activePixelCount > 0, "Limb type \(limb) should produce pixels")
        }
    }
}
