import Foundation

// MARK: - Gene Enums

enum BodyGene: String, Codable, CaseIterable {
    case round
    case square
    case oval
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
    static let canvasSize = 32

    var paletteIndex: Int {
        min(Int(personalityGene * 8), 7)
    }

    var body: BodyGene
    var eyes: EyeGene
    var limbs: LimbGene
    var pattern: PatternGene
    /// Master personality seed, 0.0~1.0
    var personalityGene: Double

    /// Derives five personality traits from the single personality gene seed.
    var personalityTraits: PersonalityTraits {
        // Use deterministic derivation from the seed
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

        let field = Int.random(in: 0..<5)
        switch field {
        case 0:
            let others = BodyGene.allCases.filter { $0 != body }
            if let pick = others.randomElement() { body = pick }
        case 1:
            let others = EyeGene.allCases.filter { $0 != eyes }
            if let pick = others.randomElement() { eyes = pick }
        case 2:
            let others = LimbGene.allCases.filter { $0 != limbs }
            if let pick = others.randomElement() { limbs = pick }
        case 3:
            let others = PatternGene.allCases.filter { $0 != pattern }
            if let pick = others.randomElement() { pattern = pick }
        case 4:
            personalityGene = Double.random(in: 0...1)
        default:
            break
        }
    }

    /// Creates a genome with random genes.
    static func random() -> PetGenome {
        PetGenome(
            body: BodyGene.allCases.randomElement()!,
            eyes: EyeGene.allCases.randomElement()!,
            limbs: LimbGene.allCases.randomElement()!,
            pattern: PatternGene.allCases.randomElement()!,
            personalityGene: Double.random(in: 0...1)
        )
    }
}
