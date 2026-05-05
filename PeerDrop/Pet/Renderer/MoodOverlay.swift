import Foundation
import UIKit

/// Mood → SF Symbol icon + tint color mapping for the v4.0 mood overlay.
///
/// Replaces the per-mood PNG sprint that was originally planned for Q3 (c).
/// Validation 2026-04-29 showed PixelLab couldn't preserve character identity
/// across mood prompt variations (commit 23b3caf), so mood is now rendered as
/// an SF Symbol composited on top of the neutral PNG sprite by M4b.2.
///
/// Icon names locked per plan §M4b.1. Tint colors picked for visual distinct-
/// ness; happy uses warm yellow, sleepy cool blue, etc.
enum MoodOverlay {

    static func iconName(_ mood: PetMood) -> String {
        switch mood {
        case .happy:    return "face.smiling"
        case .curious:  return "questionmark.circle"
        case .sleepy:   return "moon.zzz"
        case .lonely:   return "cloud.rain"
        case .excited:  return "sparkles"
        case .startled: return "exclamationmark.triangle"
        }
    }

    static func tintColor(_ mood: PetMood) -> UIColor {
        switch mood {
        case .happy:    return .systemYellow
        case .curious:  return .systemTeal
        case .sleepy:   return .systemBlue
        case .lonely:   return .systemGray
        case .excited:  return .systemPink
        case .startled: return .systemRed
        }
    }
}
