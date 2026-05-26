import CoreGraphics
import Foundation

public struct PoopState: Codable {
    public struct Poop: Identifiable, Codable {
        public let id: UUID
        public let position: CGPoint
        public let droppedAt: Date

        public init(position: CGPoint) {
            self.id = UUID()
            self.position = position
            self.droppedAt = Date()
        }
    }

    public var poops: [Poop] = []
    public let maxPoops = 3
    public let moodPenaltyDelay: TimeInterval = 600

    public init() {}

    public var hasUncleanedPoops: Bool { !poops.isEmpty }
    public var isFull: Bool { poops.count >= maxPoops }

    public var hasMoodPenalty: Bool {
        poops.contains { Date().timeIntervalSince($0.droppedAt) > moodPenaltyDelay }
    }

    public mutating func drop(at position: CGPoint) {
        guard !isFull else { return }
        poops.append(Poop(position: position))
    }

    public mutating func clean(id: UUID) -> Bool {
        guard let idx = poops.firstIndex(where: { $0.id == id }) else { return false }
        poops.remove(at: idx)
        return true
    }

    // MARK: - Codable conformance for non-stored properties
    enum CodingKeys: String, CodingKey {
        case poops
    }
}
