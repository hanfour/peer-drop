import Foundation

// MARK: - Gene Enums

enum BodyGene: String, Codable, CaseIterable {
    case cat, dog, rabbit, bird, frog, bear, dragon, octopus, ghost, slime

    /// Map legacy values from v1 genome saves
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "round": self = .bear
        case "square": self = .cat
        case "oval": self = .slime
        default:
            guard let value = BodyGene(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unknown BodyGene: \(raw)")
            }
            self = value
        }
    }

    /// Determine body type from personality gene at hatch
    static func from(personalityGene pg: Double) -> BodyGene {
        switch pg {
        case ..<0.14: return .cat
        case ..<0.28: return .dog
        case ..<0.40: return .rabbit
        case ..<0.52: return .bird
        case ..<0.62: return .frog
        case ..<0.72: return .bear
        case ..<0.80: return .dragon
        case ..<0.87: return .octopus
        case ..<0.93: return .ghost
        default:      return .slime
        }
    }
}

enum EyeGene: String, Codable, CaseIterable {
    case dot
    case round
    case line
    case dizzy
}

enum LimbGene: String, Codable, CaseIterable {
    case short
    case long
    case none
}

enum PatternGene: String, Codable, CaseIterable {
    case none
    case stripe
    case spot
}

// MARK: - PersonalityTraits

struct PersonalityTraits: Codable, Equatable {
    /// 0.0 = clingy, 1.0 = independent
    var independence: Double
    /// 0.0 = indifferent, 1.0 = very curious
    var curiosity: Double
    /// 0.0 = lazy, 1.0 = hyperactive
    var energy: Double
    /// 0.0 = bold, 1.0 = very timid
    var timidity: Double
    /// 0.0 = well-behaved, 1.0 = chaotic
    var mischief: Double

    /// Clamps all trait values to the 0.0~1.0 range.
    mutating func clamp() {
        independence = min(max(independence, 0.0), 1.0)
        curiosity = min(max(curiosity, 0.0), 1.0)
        energy = min(max(energy, 0.0), 1.0)
        timidity = min(max(timidity, 0.0), 1.0)
        mischief = min(max(mischief, 0.0), 1.0)
    }
}

// MARK: - PetGenome

struct PetGenome: Codable, Equatable {
    static let canvasSize = 16

    var paletteIndex: Int {
        let hash = (personalityGene * 137).truncatingRemainder(dividingBy: 1.0)
        return min(Int(hash * 8), 7)
    }

    var body: BodyGene
    var eyes: EyeGene
    var limbs: LimbGene?  // deprecated, kept for migration
    var pattern: PatternGene
    /// Master personality seed, 0.0~1.0
    var personalityGene: Double

    /// Derives five personality traits from the single personality gene seed.
    var personalityTraits: PersonalityTraits {
        let seed = personalityGene
        var traits = PersonalityTraits(
            independence: fmod(seed * 7.3 + 0.1, 1.0),
            curiosity: fmod(seed * 5.7 + 0.3, 1.0),
            energy: fmod(seed * 3.1 + 0.5, 1.0),
            timidity: fmod(seed * 11.3 + 0.7, 1.0),
            mischief: fmod(seed * 13.7 + 0.9, 1.0)
        )
        traits.clamp()
        return traits
    }

    /// Mutates a random gene. 30% chance normally, 100% for `.evolution`.
    mutating func mutate(trigger: InteractionType) {
        let shouldMutate = trigger == .evolution || Double.random(in: 0...1) < 0.3
        guard shouldMutate else { return }

        // Body is fixed after hatch — only eyes, pattern, personality can mutate
        let field = Int.random(in: 0..<3)
        switch field {
        case 0:
            let others = EyeGene.allCases.filter { $0 != eyes }
            if let pick = others.randomElement() { eyes = pick }
        case 1:
            let others = PatternGene.allCases.filter { $0 != pattern }
            if let pick = others.randomElement() { pattern = pick }
        case 2:
            personalityGene = Double.random(in: 0...1)
        default:
            break
        }
    }

    /// Creates a genome with random genes using personality gene to determine body.
    static func random() -> PetGenome {
        let pg = Double.random(in: 0...1)
        return PetGenome(
            body: BodyGene.from(personalityGene: pg),
            eyes: EyeGene.allCases.randomElement()!,
            pattern: PatternGene.allCases.randomElement()!,
            personalityGene: pg
        )
    }
}
