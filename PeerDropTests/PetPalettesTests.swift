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
        let low = PetGenome(body: .round, eyes: .dot, limbs: .short, pattern: .none, personalityGene: 0.0)
        XCTAssertEqual(low.paletteIndex, 0)

        let mid = PetGenome(body: .round, eyes: .dot, limbs: .short, pattern: .none, personalityGene: 0.5)
        XCTAssertEqual(mid.paletteIndex, 4)

        let high = PetGenome(body: .round, eyes: .dot, limbs: .short, pattern: .none, personalityGene: 0.99)
        XCTAssertEqual(high.paletteIndex, 7)

        let max = PetGenome(body: .round, eyes: .dot, limbs: .short, pattern: .none, personalityGene: 1.0)
        XCTAssertEqual(max.paletteIndex, 7)
    }

    func testAllPalettesHaveSixColors() {
        for (i, palette) in PetPalettes.all.enumerated() {
            for slot in 1...6 {
                XCTAssertNotNil(palette.color(for: slot), "Palette \(i) missing color for slot \(slot)")
            }
        }
    }
}
