import XCTest
@testable import PeerDrop

final class PetPalettesTests: XCTestCase {

    func testPaletteCount() {
        XCTAssertEqual(PetPalettes.all.count, 8)
    }

    func testColorForValidIndex() {
        let palette = PetPalettes.all[0]
        XCTAssertNotNil(palette.color(for: 1)) // outline
        XCTAssertNotNil(palette.color(for: 6)) // pattern
    }

    func testColorForZeroReturnsNil() {
        let palette = PetPalettes.all[0]
        XCTAssertNil(palette.color(for: 0)) // transparent
    }

    func testColorForOutOfRangeReturnsNil() {
        let palette = PetPalettes.all[0]
        XCTAssertNil(palette.color(for: 99))
    }

    func testGenomePaletteIndex() {
        // paletteIndex = min(Int((personalityGene * 137).truncatingRemainder(dividingBy: 1.0) * 8), 7)
        let g1 = PetGenome(body: .bear, eyes: .dot, pattern: .none, personalityGene: 0.0)
        XCTAssertTrue((0..<8).contains(g1.paletteIndex))

        let g2 = PetGenome(body: .bear, eyes: .dot, pattern: .none, personalityGene: 0.5)
        XCTAssertTrue((0..<8).contains(g2.paletteIndex))

        let g3 = PetGenome(body: .bear, eyes: .dot, pattern: .none, personalityGene: 0.99)
        XCTAssertTrue((0..<8).contains(g3.paletteIndex))

        let g4 = PetGenome(body: .bear, eyes: .dot, pattern: .none, personalityGene: 1.0)
        XCTAssertTrue((0..<8).contains(g4.paletteIndex))
    }

    func testAllPalettesHaveSixColors() {
        for (i, palette) in PetPalettes.all.enumerated() {
            for slot in 1...6 {
                XCTAssertNotNil(palette.color(for: slot), "Palette \(i) missing color for slot \(slot)")
            }
        }
    }
}
