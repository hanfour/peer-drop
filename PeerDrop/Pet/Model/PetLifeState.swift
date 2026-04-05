import Foundation

enum PetLifeState: String, Codable, CaseIterable {
    case sleeping
    case waking
    case active
    case napping
    case drowsy

    /// Determines life state based on current hour and energy level (0.0~1.0).
    static func current(energy: Double) -> PetLifeState {
        let hour = Calendar.current.component(.hour, from: Date())

        // Late night / early morning: sleeping
        if hour >= 0 && hour < 6 {
            return energy > 0.8 ? .napping : .sleeping
        }

        // Early morning: waking up
        if hour >= 6 && hour < 8 {
            return energy > 0.5 ? .waking : .sleeping
        }

        // Daytime: active or drowsy based on energy
        if hour >= 8 && hour < 21 {
            if energy > 0.5 {
                return .active
            } else if energy > 0.2 {
                return .drowsy
            } else {
                return .napping
            }
        }

        // Evening wind-down
        if energy > 0.6 {
            return .active
        } else if energy > 0.3 {
            return .drowsy
        } else {
            return .sleeping
        }
    }
}
