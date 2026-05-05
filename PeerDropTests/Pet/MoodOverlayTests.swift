import XCTest
import UIKit
@testable import PeerDrop

final class MoodOverlayTests: XCTestCase {

    // MARK: - icon names (locked per plan §M4b.1)

    func test_iconName_returnsExpectedSFSymbol_perMood() {
        XCTAssertEqual(MoodOverlay.iconName(.happy),    "face.smiling")
        XCTAssertEqual(MoodOverlay.iconName(.curious),  "questionmark.circle")
        XCTAssertEqual(MoodOverlay.iconName(.sleepy),   "moon.zzz")
        XCTAssertEqual(MoodOverlay.iconName(.lonely),   "cloud.rain")
        XCTAssertEqual(MoodOverlay.iconName(.excited),  "sparkles")
        XCTAssertEqual(MoodOverlay.iconName(.startled), "exclamationmark.triangle")
    }

    func test_iconName_coversAllMoods() {
        for mood in PetMood.allCases {
            XCTAssertFalse(MoodOverlay.iconName(mood).isEmpty,
                           "missing icon for \(mood)")
        }
    }

    // MARK: - tint colors

    func test_tintColor_isNonClear_forEveryMood() {
        // Sanity — every mood gets a real color (not .clear).
        for mood in PetMood.allCases {
            let color = MoodOverlay.tintColor(mood)
            var alpha: CGFloat = 0
            color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            XCTAssertGreaterThan(alpha, 0, "\(mood) tint is transparent")
        }
    }

    func test_tintColor_distinctAcrossMoods() {
        // Each mood's tint should be visually distinct so users can tell at a
        // glance which mood is rendered.
        let colors = PetMood.allCases.map { MoodOverlay.tintColor($0) }
        XCTAssertEqual(Set(colors).count, PetMood.allCases.count,
                       "two moods share the same tint color")
    }

    // MARK: - SF Symbol availability (sanity — UIImage(systemName:) resolves)

    func test_iconName_resolvesToValidSFSymbol() {
        for mood in PetMood.allCases {
            let name = MoodOverlay.iconName(mood)
            XCTAssertNotNil(UIImage(systemName: name),
                            "SF Symbol '\(name)' for \(mood) does not exist on this iOS version")
        }
    }
}
