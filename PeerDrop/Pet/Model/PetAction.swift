import Foundation

enum PetAction: String, Codable {
    // Movement
    case idle, walking, run, jump
    // Edge
    case climb, hang, fall, sitEdge
    // Life
    case sleeping, eat, yawn, poop, evolving
    // Emotion
    case happy, scared, angry, love
    // Interaction
    case tapReact, pickedUp, thrown, petted
    // Legacy (kept for migration)
    case wagTail, freeze, hideInShell, zoomies
    case notifyMessage, climbOnBubble, blockText, bounceBetweenBubbles
    case tiltHead, stuffCheeks, ignore

    // Alias for compatibility — old code references .walk
    static var walk: PetAction { .walking }
}
