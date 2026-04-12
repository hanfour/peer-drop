import Foundation

enum FoodType: String, Codable, CaseIterable, Identifiable {
    case rice, fish, apple

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .rice: return "🍚"
        case .fish: return "🐟"
        case .apple: return "🍎"
        }
    }

    var displayName: String {
        switch self {
        case .rice: return "飯糰"
        case .fish: return "小魚乾"
        case .apple: return "蘋果"
        }
    }

    var xp: Int {
        switch self {
        case .rice: return 3
        case .fish: return 5
        case .apple: return 4
        }
    }

    var moodEffect: PetMood? {
        switch self {
        case .fish: return .happy
        default: return nil
        }
    }

    var digestMinSeconds: TimeInterval {
        switch self {
        case .rice, .fish: return 1800
        case .apple: return 900
        }
    }

    var digestMaxSeconds: TimeInterval {
        switch self {
        case .rice, .fish: return 7200
        case .apple: return 3600
        }
    }
}

struct FoodItem: Codable, Identifiable, Equatable {
    let type: FoodType
    var count: Int
    var id: String { type.rawValue }
}

struct FoodInventory: Codable, Equatable {
    var items: [FoodItem] = [
        FoodItem(type: .rice, count: 3),
        FoodItem(type: .apple, count: 1),
    ]

    func count(of type: FoodType) -> Int {
        items.first(where: { $0.type == type })?.count ?? 0
    }

    @discardableResult
    mutating func consume(_ type: FoodType) -> Bool {
        guard let idx = items.firstIndex(where: { $0.type == type && $0.count > 0 }) else {
            return false
        }
        items[idx].count -= 1
        if items[idx].count <= 0 { items.remove(at: idx) }
        return true
    }

    mutating func add(_ type: FoodType, count: Int = 1) {
        if let idx = items.firstIndex(where: { $0.type == type }) {
            items[idx].count += count
        } else {
            items.append(FoodItem(type: type, count: count))
        }
    }

    mutating func applyDailyRefresh() {
        add(.rice, count: 3)
        add(.apple, count: 1)
    }
}
