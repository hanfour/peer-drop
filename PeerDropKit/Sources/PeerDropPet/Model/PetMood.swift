import Foundation

public enum PetMood: String, Codable, CaseIterable {
    case happy
    case curious
    case sleepy
    case lonely
    case excited
    case startled

    /// Localized mood label, resolved from `Localizable.xcstrings`
    /// (key `pet.mood.<rawValue>`) via `Bundle.module`. Display-only.
    public var displayName: String {
        NSLocalizedString("pet.mood.\(rawValue)", bundle: .module, comment: "Mood label for PetMood case \(rawValue)")
    }
}
