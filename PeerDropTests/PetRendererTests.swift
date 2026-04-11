import XCTest
@testable import PeerDrop

final class PetRendererTests: XCTestCase {

    private let renderer = PetRenderer()

    private func makeGenome(
        body: BodyGene = .bear,
        eyes: EyeGene = .dot,
        pattern: PatternGene = .none,
        personality: Double = 0.5
    ) -> PetGenome {
        PetGenome(body: body, eyes: eyes, pattern: pattern, personalityGene: personality)
    }

    func testRenderEggProducesPixels() {
        let genome = makeGenome()
        let grid = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 0)
        XCTAssertEqual(grid.size, 32)
        XCTAssertTrue(grid.activePixelCount > 0, "Egg should produce visible pixels")
    }

    func testRenderBabyProducesMorePixelsThanEgg() {
        let genome = makeGenome()
        let egg = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 0)
        let baby = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        XCTAssertGreaterThan(baby.activePixelCount, egg.activePixelCount)
    }

    func testDifferentGenomesProduceDifferentPixels() {
        let genome1 = makeGenome(body: .bear, eyes: .dot)
        let genome2 = makeGenome(body: .cat, eyes: .dizzy)
        let grid1 = renderer.render(genome: genome1, level: .baby, mood: .curious, animationFrame: 0)
        let grid2 = renderer.render(genome: genome2, level: .baby, mood: .curious, animationFrame: 0)
        XCTAssertNotEqual(grid1, grid2)
    }

    func testMoodAffectsEyes() {
        let genome = makeGenome()
        let happy = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        let sleepy = renderer.render(genome: genome, level: .baby, mood: .sleepy, animationFrame: 0)
        XCTAssertNotEqual(happy, sleepy)
    }

    func testEggBreathAnimation() {
        let genome = makeGenome()
        let frame0 = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 0)
        let frame1 = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 1)
        XCTAssertNotEqual(frame0, frame1)
    }

    func testEggCrackLinesAppearWithHighPersonality() {
        let lowPG = makeGenome(personality: 0.1)
        let highPG = makeGenome(personality: 0.8)
        let gridLow = renderer.render(genome: lowPG, level: .egg, mood: .happy, animationFrame: 0)
        let gridHigh = renderer.render(genome: highPG, level: .egg, mood: .happy, animationFrame: 0)
        XCTAssertGreaterThan(gridHigh.activePixelCount, gridLow.activePixelCount)
    }

    func testAllBodyTypesRender() {
        for body in BodyGene.allCases {
            let genome = makeGenome(body: body)
            let grid = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
            XCTAssertTrue(grid.activePixelCount > 0, "Body type \(body) should produce pixels")
        }
    }

    func testAllLimbTypesRender() {
        // Limbs are deprecated in v2; verify genome with legacy limbs still renders
        var genome = makeGenome()
        genome.limbs = .short
        let grid = renderer.render(genome: genome, level: .baby, mood: .curious, animationFrame: 0)
        XCTAssertTrue(grid.activePixelCount > 0)
    }

    func testGridSizeIs32() {
        let genome = makeGenome()
        let grid = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        XCTAssertEqual(grid.size, 32)
    }

    func testRenderUsesMultipleColorIndices() {
        let genome = makeGenome()
        let grid = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        let uniqueValues = Set(grid.pixels.flatMap { $0 }.filter { $0 != 0 })
        XCTAssertTrue(uniqueValues.count >= 3, "Baby should use at least 3 color indices, got \(uniqueValues)")
    }
}
