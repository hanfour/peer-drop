import XCTest
import PeerDropPet
#if canImport(UIKit)
import UIKit
#endif
@testable import PeerDropPet

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

    func test_tintColor_isNonClear_forEveryMood() throws {
#if canImport(UIKit)
        // Sanity — every mood gets a real color (not .clear).
        for mood in PetMood.allCases {
            let color = MoodOverlay.tintColor(mood)
            var alpha: CGFloat = 0
            color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            XCTAssertGreaterThan(alpha, 0, "\(mood) tint is transparent")
        }
#else
        throw XCTSkip("tintColor tests require UIKit (run on iOS simulator)")
#endif
    }

    func test_tintColor_distinctAcrossMoods() throws {
#if canImport(UIKit)
        // Each mood's tint should be visually distinct so users can tell at a
        // glance which mood is rendered.
        let colors = PetMood.allCases.map { MoodOverlay.tintColor($0) }
        XCTAssertEqual(Set(colors).count, PetMood.allCases.count,
                       "two moods share the same tint color")
#else
        throw XCTSkip("tintColor tests require UIKit (run on iOS simulator)")
#endif
    }

    // MARK: - SF Symbol availability (sanity — UIImage(systemName:) resolves)

    func test_iconName_resolvesToValidSFSymbol() throws {
#if canImport(UIKit)
        for mood in PetMood.allCases {
            let name = MoodOverlay.iconName(mood)
            XCTAssertNotNil(UIImage(systemName: name),
                            "SF Symbol '\(name)' for \(mood) does not exist on this iOS version")
        }
#else
        throw XCTSkip("SF Symbol resolution requires UIKit (run on iOS simulator)")
#endif
    }
}
