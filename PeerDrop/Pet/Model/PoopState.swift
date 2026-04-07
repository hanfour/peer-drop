import CoreGraphics
import Foundation

struct PoopState {
    struct Poop: Identifiable {
        let id = UUID()
        let position: CGPoint
        let droppedAt: Date
    }

    var poops: [Poop] = []
    let maxPoops = 3
    let moodPenaltyDelay: TimeInterval = 600

    var hasUncleanedPoops: Bool { !poops.isEmpty }
    var isFull: Bool { poops.count >= maxPoops }

    var hasMoodPenalty: Bool {
        poops.contains { Date().timeIntervalSince($0.droppedAt) > moodPenaltyDelay }
    }

    mutating func drop(at position: CGPoint) {
        guard !isFull else { return }
        poops.append(Poop(position: position, droppedAt: Date()))
    }

    mutating func clean(id: UUID) -> Bool {
        guard let idx = poops.firstIndex(where: { $0.id == id }) else { return false }
        poops.remove(at: idx)
        return true
    }
}
