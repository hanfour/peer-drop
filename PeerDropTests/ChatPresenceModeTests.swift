import XCTest
import PeerDropCore
@testable import PeerDrop

final class ChatPresenceModeTests: XCTestCase {
    func testOnlineIsLive() { XCTAssertEqual(ChatPresenceMode.mode(for: .online), .live) }
    func testNearbyIsNote() { XCTAssertEqual(ChatPresenceMode.mode(for: .nearby), .note) }
    func testOfflineIsNote() { XCTAssertEqual(ChatPresenceMode.mode(for: .offline), .note) }
    /// Project E: only `.online` is live; `.connecting` never shows the live look or the info button.
    func testOnlyOnlineIsLiveForEveryPresence() {
        for p in PeerPresence.allCases {
            XCTAssertEqual(ChatPresenceMode.mode(for: p) == .live, p == .online, "\(p)")
            XCTAssertEqual(ChatPresenceMode.showsInfoButton(presence: p), p == .online, "\(p)")
        }
    }

    func testDisconnectedOverridesOnline() {
        XCTAssertEqual(ChatPresenceMode.mode(presence: .online, isDisconnected: true), .note)
        XCTAssertEqual(ChatPresenceMode.mode(presence: .online, isDisconnected: false), .live)
        XCTAssertEqual(ChatPresenceMode.mode(presence: .offline, isDisconnected: false), .note)
    }

    func testLiveOutgoingQuoteBarReadableOnBubble() {
        for dark in [false, true] {
            let bar = PaperPalette.hex(.outgoingQuoteBar, dark: dark, mode: .live)
            let bubble = PaperPalette.hex(.outgoingBubble, dark: dark, mode: .live)
            XCTAssertGreaterThanOrEqual(PaperPalette.contrastRatio(bar, bubble), 3.0, "dark=\(dark)")
        }
    }

    func testNoteOutgoingQuoteBarUnchanged() {
        for dark in [false, true] {
            XCTAssertEqual(PaperPalette.hex(.outgoingQuoteBar, dark: dark, mode: .note),
                           PaperPalette.hex(.quoteBar, dark: dark, mode: .note))
        }
    }

    func testLiveAttachTintsDistinctAndCarryWhiteGlyph() {
        for dark in [false, true] {
            let hexes = [PaperToken.attachCamera, .attachPhotos, .attachFiles].map { PaperPalette.hex($0, dark: dark, mode: .live) }
            XCTAssertEqual(Set(hexes).count, 3)
            for h in hexes { XCTAssertGreaterThanOrEqual(PaperPalette.contrastRatio(h, 0xFFFFFF), 3.0) }
        }
    }

    func testNoteAttachTintsUnchanged() {
        for dark in [false, true] {
            XCTAssertEqual(PaperPalette.hex(.attachCamera, dark: dark, mode: .note), PaperPalette.hex(.quoteBar, dark: dark, mode: .note))
            XCTAssertEqual(PaperPalette.hex(.attachPhotos, dark: dark, mode: .note), PaperPalette.hex(.outgoingBubble, dark: dark, mode: .note))
            XCTAssertEqual(PaperPalette.hex(.attachFiles, dark: dark, mode: .note), PaperPalette.hex(.sendButton, dark: dark, mode: .note))
        }
    }
}
