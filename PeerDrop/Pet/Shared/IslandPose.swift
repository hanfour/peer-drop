enum IslandPose: String, Codable, Hashable {
    case sitting, sleeping, happy, eating, pooping, lonely

    static func from(mood: PetMood) -> IslandPose {
        switch mood {
        case .sleepy: return .sleeping
        case .happy, .excited: return .happy
        case .lonely: return .lonely
        case .startled, .curious: return .sitting
        }
    }

    var action: PetAction {
        switch self {
        case .sitting: return .idle
        case .sleeping: return .sleeping
        case .happy: return .happy
        case .eating: return .eat
        case .pooping: return .poop
        case .lonely: return .idle
        }
    }
}
