import XCTest
import PeerDropCore
@testable import PeerDrop

final class PeerAvatarTests: XCTestCase {
    func testCornerRadius() {
        XCTAssertEqual(PeerAvatarShape.cornerRadius(forSize: 44), 16, accuracy: 0.001)
        XCTAssertEqual(PeerAvatarShape.cornerRadius(forSize: 40), 14.4, accuracy: 0.001)
        XCTAssertEqual(PeerAvatarShape.cornerRadius(forSize: 32), 11.52, accuracy: 0.001)
        XCTAssertEqual(PeerAvatarShape.cornerRadius(forSize: 64), 16, accuracy: 0.001)
    }

    func testSwatchStableForName() {
        XCTAssertEqual(PeerAvatarPalette.swatch(for: "Mika"), PeerAvatarPalette.swatch(for: "Mika"))
        XCTAssertEqual(PeerAvatarPalette.swatches.count, 4)
        for name in ["Mika", "小安"] {
            let i = PeerAvatarPalette.index(for: name, count: PeerAvatarPalette.swatches.count)
            XCTAssertTrue((0..<4).contains(i))
            XCTAssertEqual(PeerAvatarPalette.swatch(for: name), PeerAvatarPalette.swatches[i])
        }
    }

    func testSwatchLabelContrast() {
        for s in PeerAvatarPalette.swatches {
            let r = PaperPalette.contrastRatio(s.label, s.fill)
            XCTAssertGreaterThanOrEqual(r, 4.5, "fill \(String(s.fill, radix: 16)) ratio \(r)")
        }
    }

    func testPresenceAccessibilityLabelsDistinct() {
        let labels = [PeerPresence.online, .nearby, .offline].map(\.accessibilityLabel)
        XCTAssertEqual(Set(labels).count, 3)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
    }
}
