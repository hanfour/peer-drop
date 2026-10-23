import XCTest
@testable import PeerDrop
@testable import PeerDropCore

final class PaperThemeTests: XCTestCase {
    func testTextPairsMeetAA() {
        let pairs: [(PaperToken, PaperToken)] = [
            (.incomingText, .incomingBubble),
            (.outgoingText, .outgoingBubble),
            (.incomingText, .background),
            (.datePillText, .datePillFill),
        ]
        for dark in [false, true] {
            for (fg, bg) in pairs {
                let r = PaperPalette.contrastRatio(PaperPalette.hex(fg, dark: dark), PaperPalette.hex(bg, dark: dark))
                XCTAssertGreaterThanOrEqual(r, 4.5, "\(fg) on \(bg) dark=\(dark) ratio \(r)")
            }
        }
    }

    func testPlaceholderMeets3to1() {
        for dark in [false, true] {
            let r = PaperPalette.contrastRatio(PaperPalette.hex(.inputPlaceholder, dark: dark), PaperPalette.hex(.inputFill, dark: dark))
            XCTAssertGreaterThanOrEqual(r, 3.0, "placeholder dark=\(dark) ratio \(r)")
        }
    }

    func testDeliveredAndReadTicksAreDistinctAndNotBlue() {
        for dark in [false, true] {
            XCTAssertNotEqual(PaperPalette.hex(.tickDelivered, dark: dark), PaperPalette.hex(.tickRead, dark: dark))
            let h = PaperPalette.hex(.tickRead, dark: dark)
            let r = (h >> 16) & 0xFF, g = (h >> 8) & 0xFF, b = h & 0xFF
            XCTAssertFalse(b > r && b > g, "tickRead must not be blue-ish (dark=\(dark))")
        }
    }

    func testTickTokensContrastOnOutgoingBubble() {
        for dark in [false, true] {
            for t in [PaperToken.tickSent, .tickDelivered, .tickRead, .tickFailed] {
                let r = PaperPalette.contrastRatio(PaperPalette.hex(t, dark: dark), PaperPalette.hex(.outgoingBubble, dark: dark))
                XCTAssertGreaterThanOrEqual(r, 3.0, "\(t) dark=\(dark) ratio \(r)")
            }
        }
    }

    func testTickTokenMapping() {
        XCTAssertNotEqual(PaperTheme.tick(for: .delivered), PaperTheme.tick(for: .read))
        XCTAssertEqual(PaperTheme.tick(for: .failed), .tickFailed)
        XCTAssertEqual(PaperTheme.tick(for: .sending), .tickSent)
        XCTAssertEqual(PaperTheme.tick(for: .sent), .tickSent)
        XCTAssertEqual(PaperTheme.tick(for: .delivered), .tickDelivered)
        XCTAssertEqual(PaperTheme.tick(for: .read), .tickRead)
    }

    func testContrastRatioKnownValues() {
        XCTAssertEqual(PaperPalette.contrastRatio(0x000000, 0xFFFFFF), 21.0, accuracy: 0.01)
        XCTAssertEqual(PaperPalette.contrastRatio(0x777777, 0xFFFFFF), 4.48, accuracy: 0.05)
    }
}
