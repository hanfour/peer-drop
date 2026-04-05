import Foundation

// Defined here temporarily, will be moved to InteractionTracker in Task 2
enum InteractionType: String, Codable, CaseIterable {
    case tap
    case shake
    case charge
    case steps
    case peerConnected
    case chatActive
    case fileTransfer
    case petMeeting
    case evolution

    var experienceValue: Int {
        switch self {
        case .tap: return 2
        case .shake: return 3
        case .charge: return 1
        case .steps: return 1
        case .peerConnected: return 5
        case .chatActive: return 2
        case .fileTransfer: return 3
        case .petMeeting: return 10
        case .evolution: return 0
        }
    }
}
