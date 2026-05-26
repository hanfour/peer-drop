import Foundation

public enum PetMood: String, Codable, CaseIterable {
    case happy
    case curious
    case sleepy
    case lonely
    case excited
    case startled

    public var displayName: String {
        switch self {
        case .happy: return "開心"
        case .curious: return "好奇"
        case .sleepy: return "想睡"
        case .lonely: return "寂寞"
        case .excited: return "興奮"
        case .startled: return "嚇到"
        }
    }
}
