import Foundation

public enum FoodType: String, Codable, CaseIterable, Identifiable {
    case rice, fish, apple

    public var id: String { rawValue }

    public var emoji: String {
        switch self {
        case .rice: return "🍚"
        case .fish: return "🐟"
        case .apple: return "🍎"
        }
    }

    public var displayName: String {
        switch self {
        case .rice: return "飯糰"
        case .fish: return "小魚乾"
        case .apple: return "蘋果"
        }
    }

    public var xp: Int {
        switch self {
        case .rice: return 3
        case .fish: return 5
        case .apple: return 4
        }
    }

    public var moodEffect: PetMood? {
        switch self {
        case .fish: return .happy
        default: return nil
        }
    }

    public var digestMinSeconds: TimeInterval {
        switch self {
        case .rice, .fish: return 1800
        case .apple: return 900
        }
    }

    public var digestMaxSeconds: TimeInterval {
        switch self {
        case .rice, .fish: return 7200
        case .apple: return 3600
        }
    }
}

public struct FoodItem: Codable, Identifiable, Equatable {
    public let type: FoodType
    public var count: Int
    public var id: String { type.rawValue }
    public init(type: FoodType, count: Int) { self.type = type; self.count = count }
}

public struct FoodInventory: Codable, Equatable {
    public var items: [FoodItem] = [
        FoodItem(type: .rice, count: 3),
        FoodItem(type: .apple, count: 1),
    ]

    public init() {}

    public func count(of type: FoodType) -> Int {
        items.first(where: { $0.type == type })?.count ?? 0
    }

    @discardableResult
    public mutating func consume(_ type: FoodType) -> Bool {
        guard let idx = items.firstIndex(where: { $0.type == type && $0.count > 0 }) else {
            return false
        }
        items[idx].count -= 1
        if items[idx].count <= 0 { items.remove(at: idx) }
        return true
    }

    /// Add `count` units of `type`. Inventory only ever grows through this
    /// path, so non-positive counts are ignored (they'd otherwise produce a
    /// negative on-screen count) and additions saturate at `Int.max` instead
    /// of overflowing.
    public mutating func add(_ type: FoodType, count: Int = 1) {
        guard count > 0 else { return }
        if let idx = items.firstIndex(where: { $0.type == type }) {
            let (sum, overflowed) = items[idx].count.addingReportingOverflow(count)
            items[idx].count = overflowed ? Int.max : sum
        } else {
            items.append(FoodItem(type: type, count: count))
        }
    }

    public mutating func applyDailyRefresh() {
        add(.rice, count: 3)
        add(.apple, count: 1)
    }
}
