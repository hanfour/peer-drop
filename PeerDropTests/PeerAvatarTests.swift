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
        let labels = PeerPresence.allCases.map(\.accessibilityLabel)
        XCTAssertEqual(PeerPresence.allCases.count, 4)
        XCTAssertEqual(Set(labels).count, PeerPresence.allCases.count)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
    }

    /// Project E: "connecting" (waiting / negotiating across networks) is never "Online".
    func testConnectingAccessibilityLabel() {
        let label = PeerPresence.connecting.accessibilityLabel
        XCTAssertEqual(label, String(localized: "Connecting, not online yet"))
        XCTAssertNotEqual(label, PeerPresence.online.accessibilityLabel)
        XCTAssertEqual(PeerPresence.connecting.accessibilityLabel(notesReachable: true), label)
    }

    /// Every state has its own shape: state is never conveyed by colour alone.
    func testEveryPresenceHasADistinctBadgeShape() {
        var shapes: [PresenceBadge.Shape] = []
        for p in PeerPresence.allCases {
            shapes.append(PresenceBadge.shape(for: p, notesReachable: false))
            if p == .offline { shapes.append(PresenceBadge.shape(for: p, notesReachable: true)) }
        }
        XCTAssertEqual(shapes.count, 5)
        XCTAssertEqual(Set(shapes).count, shapes.count, "\(shapes)")
        XCTAssertEqual(PresenceBadge.shape(for: .connecting, notesReachable: false), .dashedRing)
        XCTAssertEqual(PresenceBadge.shape(for: .connecting, notesReachable: true), .dashedRing)
    }

    /// Only a VERIFIED binding makes "you can send notes" true; an unbound offline friend's thread is locked.
    func testOfflineLabelDependsOnNotesReachable() {
        let plain = PeerPresence.offline.accessibilityLabel(notesReachable: false)
        let notes = PeerPresence.offline.accessibilityLabel(notesReachable: true)
        XCTAssertNotEqual(plain, notes)
        XCTAssertEqual(plain, String(localized: "Offline"))
        XCTAssertEqual(notes, String(localized: "Offline, you can send notes"))
        // Default (no binding knowledge) never over-promises.
        XCTAssertEqual(PeerPresence.offline.accessibilityLabel, plain)
        // Online / nearby are unaffected by the flag.
        XCTAssertEqual(PeerPresence.online.accessibilityLabel(notesReachable: true), PeerPresence.online.accessibilityLabel)
        XCTAssertEqual(PeerPresence.nearby.accessibilityLabel(notesReachable: true), PeerPresence.nearby.accessibilityLabel)
    }

    func testAvatarAccessibilityTextUsesNotesReachable() {
        XCTAssertTrue(PeerAvatar.accessibilityText(name: "Mika", presence: .offline, notesReachable: true).contains(String(localized: "Offline, you can send notes")))
        XCTAssertFalse(PeerAvatar.accessibilityText(name: "Mika", presence: .offline, notesReachable: false).contains(String(localized: "you can send notes")))
    }

    func testOfflineBadgeKind() {
        XCTAssertEqual(PresenceBadge.offlineKind(notesReachable: true), .notes)
        XCTAssertEqual(PresenceBadge.offlineKind(notesReachable: false), .neutral)
    }

    func testBadgeDiameter() {
        XCTAssertEqual(PresenceBadge.diameter(forAvatarSize: 32), 12, accuracy: 0.001)
        XCTAssertEqual(PresenceBadge.diameter(forAvatarSize: 40), 14.4, accuracy: 0.001)
        XCTAssertEqual(PresenceBadge.diameter(forAvatarSize: 64), 23.04, accuracy: 0.001)
    }

    func testAccessibilityHiddenOnlyWithoutPresence() {
        XCTAssertTrue(PeerAvatar.isAccessibilityHidden(presence: nil))
        for p in PeerPresence.allCases {
            XCTAssertFalse(PeerAvatar.isAccessibilityHidden(presence: p))
        }
        let text = PeerAvatar.accessibilityText(name: "Mika", presence: .offline)
        XCTAssertTrue(text.contains("Mika"))
        XCTAssertTrue(text.contains(PeerPresence.offline.accessibilityLabel))
    }
}
