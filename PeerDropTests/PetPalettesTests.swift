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

    func testGenomePaletteIndexInRange() {
        for pg in stride(from: 0.0, through: 1.0, by: 0.1) {
            let genome = PetGenome(body: .bear, eyes: .dot, pattern: .none, personalityGene: pg)
            XCTAssertTrue((0..<8).contains(genome.paletteIndex),
                          "paletteIndex \(genome.paletteIndex) out of range for pg=\(pg)")
        }
    }

    func testAllPalettesHaveSixColors() {
        for (i, palette) in PetPalettes.all.enumerated() {
            for slot in 1...6 {
                XCTAssertNotNil(palette.color(for: slot), "Palette \(i) missing color for slot \(slot)")
            }
        }
    }
}
