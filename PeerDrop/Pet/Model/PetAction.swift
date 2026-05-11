import Foundation

enum PetAction: String, Codable, CaseIterable {
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

    // MARK: - Species-Specific Actions

    // Cat
    case scratch, stretch, groom, nap
    // Dog (wagTail already in Legacy)
    case dig, fetchToy, scratchWall
    // Rabbit
    case burrow, nibble, alertEars, binky
    // Bird
    case perch, peck, preen, dive, glide
    // Frog
    case tongueSnap, croak, swim, stickyWall
    // Bear
    case backScratch, standUp, pawSlam, bigYawn
    // Dragon
    case breathFire, hover, wingSpread, roar
    // Octopus
    case inkSquirt, tentacleReach, camouflage, wallSuction
    // Slime
    case split, melt, absorb, wallStick

    // Alias for compatibility — old code references .walk
    static var walk: PetAction { .walking }
}
