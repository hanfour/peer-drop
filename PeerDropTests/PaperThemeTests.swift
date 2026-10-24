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

    func testBannerAndGroupStripPairsMeetContrast() {
        // Disconnect banner / group strip: text on page background, pill fill and border fills.
        let text: [(PaperToken, PaperToken)] = [
            (.incomingText, .datePillFill),   // "Back to Nearby" label on its fill
            (.incomingText, .border),
            (.datePillText, .background),
            (.datePillText, .datePillFill),   // "N/M connected" on the strip
        ]
        for dark in [false, true] {
            for (fg, bg) in text {
                let r = PaperPalette.contrastRatio(PaperPalette.hex(fg, dark: dark), PaperPalette.hex(bg, dark: dark))
                XCTAssertGreaterThanOrEqual(r, 4.5, "\(fg) on \(bg) dark=\(dark) ratio \(r)")
            }
            // Disabled send arrow (inputPlaceholder) on the page background.
            let d = PaperPalette.contrastRatio(PaperPalette.hex(.inputPlaceholder, dark: dark), PaperPalette.hex(.background, dark: dark))
            XCTAssertGreaterThanOrEqual(d, 3.0, "disabled send dark=\(dark) ratio \(d)")
        }
    }

    func testWarningIconVisibleOnBannerFill() {
        for dark in [false, true] {
            let r = PaperPalette.contrastRatio(PaperPalette.hex(.warning, dark: dark), PaperPalette.hex(.datePillFill, dark: dark))
            XCTAssertGreaterThanOrEqual(r, 3.0, "warning on datePillFill dark=\(dark) ratio \(r)")
        }
    }

    func testAccentTintReadableOnBackground() {
        for dark in [false, true] {
            let r = PaperPalette.contrastRatio(PaperPalette.hex(.accent, dark: dark), PaperPalette.hex(.background, dark: dark))
            XCTAssertGreaterThanOrEqual(r, 4.5, "accent on background dark=\(dark) ratio \(r)")
        }
    }

    func testReadTickIsTheEmphasisedOneInDarkMode() {
        // Dark: read is the light, high-attention tick; sent/delivered match the dark timestamp tone.
        let bubble = PaperPalette.hex(.outgoingBubble, dark: true)
        let lightTone = PaperPalette.contrastRatio(PaperPalette.hex(.tickRead, dark: true), PaperPalette.hex(.outgoingText, dark: true))
        let delivered = PaperPalette.contrastRatio(PaperPalette.hex(.tickDelivered, dark: true), PaperPalette.hex(.outgoingText, dark: true))
        XCTAssertGreaterThan(lightTone, delivered, "read must stand out from delivered in dark mode (bubble \(bubble))")
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

    func testAccentFillGlyphsMeetContrast() {
        // Attachment icons: outgoingText glyph on quoteBar / outgoingBubble / sendButton fills (>= 3:1).
        // Verify button + reply swipe: white label on tickRead fill (>= 4.5:1).
        for dark in [false, true] {
            for fill in [PaperToken.quoteBar, .outgoingBubble, .sendButton] {
                let r = PaperPalette.contrastRatio(PaperPalette.hex(.outgoingText, dark: dark), PaperPalette.hex(fill, dark: dark))
                XCTAssertGreaterThanOrEqual(r, 3.0, "outgoingText on \(fill) dark=\(dark): \(r)")
            }
            // (white-on-tickRead assertion removed: Verify/Reply now use `actionFill`,
            // covered by testActionFillWorksWithWhiteLabelAndOnBackground.)
        }
    }

    func testActionFillWorksWithWhiteLabelAndOnBackground() {
        // Swipe Reply / Verify / Reconnect: SwiftUI draws the label white on the tint,
        // so one fill must carry white at >= 4.5:1 and read as a shape (>= 3:1) on the page.
        for dark in [false, true] {
            let fill = PaperPalette.hex(.actionFill, dark: dark)
            let shape = PaperPalette.contrastRatio(fill, PaperPalette.hex(.background, dark: dark))
            XCTAssertGreaterThanOrEqual(shape, 3.0, "actionFill vs background dark=\(dark): \(shape)")
            let label = PaperPalette.contrastRatio(0xFFFFFF, fill)
            XCTAssertGreaterThanOrEqual(label, 4.5, "white on actionFill dark=\(dark): \(label)")
        }
    }

    func testContrastRatioKnownValues() {
        XCTAssertEqual(PaperPalette.contrastRatio(0x000000, 0xFFFFFF), 21.0, accuracy: 0.01)
        XCTAssertEqual(PaperPalette.contrastRatio(0x777777, 0xFFFFFF), 4.48, accuracy: 0.05)
    }

    // MARK: - live / note modes

    func testLiveTextPairsMeetAA() {
        let pairs: [(PaperToken, PaperToken)] = [
            (.incomingText, .incomingBubble), (.outgoingText, .outgoingBubble),
            (.incomingText, .background), (.datePillText, .datePillFill),
        ]
        for dark in [false, true] {
            for (fg, bg) in pairs {
                let r = PaperPalette.contrastRatio(PaperPalette.hex(fg, dark: dark, mode: .live), PaperPalette.hex(bg, dark: dark, mode: .live))
                XCTAssertGreaterThanOrEqual(r, 4.5, "live \(fg) on \(bg) dark=\(dark) ratio \(r)")
            }
        }
    }

    func testLiveNonTextMeets3to1() {
        func h(_ t: PaperToken, _ d: Bool) -> UInt32 { PaperPalette.hex(t, dark: d, mode: .live) }
        for dark in [false, true] {
            var pairs: [(PaperToken, PaperToken)] = [
                (.inputPlaceholder, .inputFill), (.highlight, .background), (.online, .background),
            ]
            pairs += [PaperToken.tickSent, .tickDelivered, .tickRead].map { ($0, PaperToken.outgoingBubble) }
            for (fg, bg) in pairs {
                let r = PaperPalette.contrastRatio(h(fg, dark), h(bg, dark))
                XCTAssertGreaterThanOrEqual(r, 3.0, "live \(fg) on \(bg) dark=\(dark) ratio \(r)")
            }
            let ticks = Set([h(.tickSent, dark), h(.tickDelivered, dark), h(.tickRead, dark)])
            XCTAssertEqual(ticks.count, 3, "live ticks must be pairwise distinct (dark=\(dark))")
        }
    }

    func testLiveAccentReadableOnBackground() {
        for dark in [false, true] {
            let r = PaperPalette.contrastRatio(PaperPalette.hex(.accent, dark: dark, mode: .live), PaperPalette.hex(.background, dark: dark, mode: .live))
            XCTAssertGreaterThanOrEqual(r, 4.5, "live accent dark=\(dark) ratio \(r)")
        }
    }

    func testBrandWithWhiteLabel() {
        for mode in [PaperMode.live, .note] {
            for dark in [false, true] {
                let r = PaperPalette.contrastRatio(0xFFFFFF, PaperPalette.hex(.brand, dark: dark, mode: mode))
                XCTAssertGreaterThanOrEqual(r, 4.5, "white on brand \(mode) dark=\(dark) ratio \(r)")
            }
        }
    }

    func testNoteTokensContrast() {
        for dark in [false, true] {
            let t = PaperPalette.contrastRatio(PaperPalette.hex(.noteText, dark: dark), PaperPalette.hex(.noteFill, dark: dark))
            XCTAssertGreaterThanOrEqual(t, 4.5, "noteText on noteFill dark=\(dark) ratio \(t)")
            for mode in [PaperMode.live, .note] {
                let b = PaperPalette.contrastRatio(PaperPalette.hex(.noteBorder, dark: dark, mode: mode), PaperPalette.hex(.background, dark: dark, mode: mode))
                XCTAssertGreaterThanOrEqual(b, 3.0, "noteBorder on background \(mode) dark=\(dark) ratio \(b)")
            }
        }
    }

    func testNoteGlyphOnBadgeAndPresenceOnNoteBackground() {
        for dark in [false, true] {
            // Glyph on the amber badge: noteText in light; dark's noteText is light-on-dark
            // (for noteFill), so the badge glyph there is the dark outgoingText-style 0x1F1610.
            let glyph: UInt32 = dark ? 0x1F1610 : PaperPalette.hex(.noteText, dark: false)
            let g = PaperPalette.contrastRatio(glyph, PaperPalette.hex(.noteBadge, dark: dark))
            XCTAssertGreaterThanOrEqual(g, 4.5, "glyph on noteBadge dark=\(dark) ratio \(g)")
            XCTAssertEqual(PaperPalette.hex(.noteBadge, dark: dark), 0xF9A825)
            for t in [PaperToken.online, .highlight] {
                let r = PaperPalette.contrastRatio(PaperPalette.hex(t, dark: dark, mode: .note), PaperPalette.hex(.background, dark: dark, mode: .note))
                XCTAssertGreaterThanOrEqual(r, 3.0, "\(t) on note background dark=\(dark) ratio \(r)")
            }
        }
    }

    func testModeIndependentTokensAreEqualAcrossModes() {
        for token in [PaperToken.brand, .highlight, .online, .noteFill, .noteBorder, .noteText, .noteBadge] {
            for dark in [false, true] {
                XCTAssertEqual(PaperPalette.hex(token, dark: dark, mode: .live), PaperPalette.hex(token, dark: dark, mode: .note), "\(token) dark=\(dark)")
            }
        }
    }

    func testDefaultModeIsNoteAndUnchanged() {
        XCTAssertEqual(PaperPalette.hex(.background, dark: false), 0xFBF6EE)
        XCTAssertEqual(PaperPalette.hex(.background, dark: true), 0x2A221C)
    }

    func testLiveBackgroundValues() {
        XCTAssertEqual(PaperPalette.hex(.background, dark: false, mode: .live), 0xF4F9FD)
        XCTAssertEqual(PaperPalette.hex(.border, dark: false, mode: .live), 0xDDEAF4)
        XCTAssertEqual(PaperPalette.hex(.incomingText, dark: false, mode: .live), 0x1E2B36)
    }

    func testNoteFailedMeetsAAOnNoteFillInBothAppearances() {
        for dark in [false, true] {
            let r = PaperPalette.contrastRatio(PaperPalette.hex(.noteFailed, dark: dark), PaperPalette.hex(.noteFill, dark: dark))
            XCTAssertGreaterThanOrEqual(r, 4.5, "dark=\(dark) ratio \(r)")
        }
    }
}
