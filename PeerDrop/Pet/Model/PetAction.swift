import Foundation

enum PetAction: String, Codable {
    // Basic
    case idle
    case walking
    case sleeping
    case evolving

    // Emotion
    case wagTail
    case freeze
    case hideInShell
    case zoomies

    // Chat-aware
    case notifyMessage
    case climbOnBubble
    case blockText
    case bounceBetweenBubbles
    case tiltHead
    case stuffCheeks
    case ignore
}
