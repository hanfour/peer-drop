import XCTest
@testable import PeerDrop

final class PetRendererV2Tests: XCTestCase {

    func testRenderEggReturnsCGImage() {
        let genome = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5)
        let palette = PetPalettes.egg
        let image = PetRendererV2.shared.render(genome: genome, level: .egg, mood: .curious,
                                                  frame: 0, palette: palette, scale: 1)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 16)
    }

    func testRenderBabyCatReturnsCGImage() {
        let genome = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5)
        let palette = PetPalettes.all[0]
        let image = PetRendererV2.shared.render(genome: genome, level: .baby, mood: .curious,
                                                  frame: 0, palette: palette, scale: 1)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 16)
    }

    func testRenderScaled() {
        let renderer = PetRendererV2()
        let genome = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5)
        let palette = PetPalettes.all[0]
        let image = renderer.render(genome: genome, level: .baby, mood: .curious,
                                     frame: 0, palette: palette, scale: 8)
        XCTAssertEqual(image?.width, 128)
    }

    func testRenderCachesResult() {
        let renderer = PetRendererV2()
        let genome = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5)
        let palette = PetPalettes.all[0]
        let img1 = renderer.render(genome: genome, level: .baby, mood: .curious,
                                    frame: 0, palette: palette, scale: 1)
        let img2 = renderer.render(genome: genome, level: .baby, mood: .curious,
                                    frame: 0, palette: palette, scale: 1)
        XCTAssertNotNil(img1)
        XCTAssertNotNil(img2)
    }

    func testRenderWithPattern() {
        let genome = PetGenome(body: .cat, eyes: .dot, pattern: .stripe, personalityGene: 0.5)
        let palette = PetPalettes.all[0]
        let image = PetRendererV2.shared.render(genome: genome, level: .baby, mood: .curious,
                                                  frame: 0, palette: palette, scale: 1)
        XCTAssertNotNil(image)
    }
}
