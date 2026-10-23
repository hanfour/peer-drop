import XCTest
@testable import PeerDrop

final class PeerAvatarPaletteTests: XCTestCase {
    func testIndexIsDeterministicWithKnownValues() {
        // FNV-1a (32-bit) over unicode scalars, modulo count.
        XCTAssertEqual(PeerAvatarPalette.index(for: "Mika", count: 6), 5)
        XCTAssertEqual(PeerAvatarPalette.index(for: "Bob", count: 6), 4)
        for _ in 0..<5 {
            XCTAssertEqual(PeerAvatarPalette.index(for: "Mika", count: 6), 5)
        }
    }

    func testIndexStaysInRange() {
        for name in ["", "A", "Mika", "小明", "😀 Emoji", String(repeating: "x", count: 500)] {
            for count in [1, 2, 6, 7] {
                let i = PeerAvatarPalette.index(for: name, count: count)
                XCTAssertTrue((0..<count).contains(i), "\(name) count \(count) -> \(i)")
            }
        }
    }

    func testZeroCountAndEmptyName() {
        XCTAssertEqual(PeerAvatarPalette.index(for: "x", count: 0), 0)
        for count in [1, 6] {
            let i = PeerAvatarPalette.index(for: "", count: count)
            XCTAssertTrue((0..<count).contains(i))
        }
    }

    func testWaveformHeightsAreStableAndInRange() {
        let first = (0..<20).map { VoiceWaveform.height(forMessageID: "msg-123", index: $0) }
        let second = (0..<20).map { VoiceWaveform.height(forMessageID: "msg-123", index: $0) }
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0 >= 4 && $0 <= 20 })
        XCTAssertNotEqual(first, (0..<20).map { VoiceWaveform.height(forMessageID: "other-id", index: $0) })
    }

    func testDifferentNamesSpreadAcrossPalette() {
        let names = ["Mika", "Bob", "Alice", "Carol", "Dave", "Eve", "Frank", "Grace"]
        let indices = Set(names.map { PeerAvatarPalette.index(for: $0, count: 6) })
        XCTAssertGreaterThan(indices.count, 1)
    }

    func testPaperPaletteHasSixColoursWithWhiteInitialsContrast() {
        XCTAssertEqual(PeerAvatarPalette.paperHex.count, 6)
        for hex in PeerAvatarPalette.paperHex {
            let r = PaperPalette.contrastRatio(0xFFFFFF, hex)
            XCTAssertGreaterThanOrEqual(r, 4.5, "white on \(String(hex, radix: 16)) ratio \(r)")
        }
    }
}
