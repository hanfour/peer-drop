import Foundation

struct PetSnapshot: Codable, Equatable {
    let name: String?
    let bodyType: BodyGene
    let eyeType: EyeGene
    let patternType: PatternGene
    let level: PetLevel
    let mood: PetMood
    let paletteIndex: Int
    let experience: Int
    let maxExperience: Int
}

class SharedPetState {
    static let appGroupID = "group.com.hanfour.peerdrop"
    private static let key = "petSnapshot"
    private let defaults: UserDefaults

    init(suiteName: String? = appGroupID) {
        if let suite = suiteName {
            self.defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            self.defaults = .standard
        }
    }

    func write(_ snapshot: PetSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func read() -> PetSnapshot? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PetSnapshot.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
