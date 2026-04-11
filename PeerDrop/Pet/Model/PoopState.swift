import CoreGraphics
import Foundation

struct PoopState: Codable {
    struct Poop: Identifiable, Codable {
        let id: UUID
        let position: CGPoint
        let droppedAt: Date

        init(position: CGPoint) {
            self.id = UUID()
            self.position = position
            self.droppedAt = Date()
        }
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
        poops.append(Poop(position: position))
    }

    mutating func clean(id: UUID) -> Bool {
        guard let idx = poops.firstIndex(where: { $0.id == id }) else { return false }
        poops.remove(at: idx)
        return true
    }

    // MARK: - Codable conformance for non-stored properties
    enum CodingKeys: String, CodingKey {
        case poops
    }
}
