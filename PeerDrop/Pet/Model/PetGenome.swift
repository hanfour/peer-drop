import Foundation

// MARK: - Gene Enums

enum BodyGene: String, Codable, CaseIterable {
    case cat, dog, rabbit, bird, frog, bear, dragon, octopus, ghost, slime

    /// Map legacy values from v1 genome saves
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "round": self = .bear
        case "square": self = .cat
        case "oval": self = .slime
        default:
            guard let value = BodyGene(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown BodyGene: \(raw)")
            }
            self = value
        }
    }

    /// Determine body type from personality gene at hatch.
    ///
    /// **v5.0 distribution shift (2026-05-09):** cat family weight raised
    /// from 14% to 40%, ghost weight raised from 6% to 10%. Reason: in
    /// v5.0's initial release, cat-tabby and ghost are the only species
    /// shipping at v5 schema (multi-frame walk animations). Other species
    /// gain animations across subsequent updates per the weekly cadence
    /// in `docs/release/v5.0.x-cadence.md`. Skewing the genome distribution
    /// toward animated species during the rollout window means newly-
    /// hatched pets are more likely to demonstrate the v5 animation
    /// pipeline that the release notes advertise.
    ///
    /// As more species reach v5 schema, this distribution should rebalance
    /// back toward uniform — track in the cadence playbook.
    static func from(personalityGene pg: Double) -> BodyGene {
        switch pg {
        case ..<0.40: return .cat       // 40% (v5 animated; was 14%)
        case ..<0.50: return .ghost     // 10% (v5 animated; was 6% range)
        case ..<0.60: return .dog       // 10% (v4 static, common; was 14%)
        case ..<0.68: return .rabbit    // 8%  (was 12%)
        case ..<0.76: return .bird      // 8%  (was 12%)
        case ..<0.82: return .frog      // 6%  (was 10%)
        case ..<0.88: return .bear      // 6%  (was 10%)
        case ..<0.92: return .dragon    // 4%  (was 8%)
        case ..<0.96: return .octopus   // 4%  (was 7%)
        default:      return .slime     // 4%  (was 7%)
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
    /// v4.0: pinned sub-variety string (e.g. "tabby" for body=.cat → "cat-tabby").
    /// Optional: legacy v3.x JSON decodes as nil, then PetStore migration (M7.2)
    /// assigns a default. Once set, takes precedence over the seed-based pick.
    var subVariety: String?
    /// v4.0: per-pet deterministic seed for sub-variety re-rolls and future
    /// stochastic genome features. Optional: legacy pets get a seed assigned by
    /// PetStore migration (M7.2) via hash(petId + petName).
    var seed: UInt32?

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
    /// `subVariety` and `seed` are intentionally NOT mutation candidates: sub-variety
    /// is stable visual identity (set once at hatch / migration), and seed governs
    /// the deterministic re-roll path used by M7.2 — re-rolling either at evolution
    /// would change the pet's species mid-life, which is not a v4.0 design goal.
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
    /// Also assigns a random `seed` so the v4.0 sub-variety resolver picks one
    /// of the family's variants — without a seed, every freshly-hatched cat would
    /// render as cat-tabby and the species catalog would be unreachable for new pets.
    static func random() -> PetGenome {
        let pg = Double.random(in: 0...1)
        return PetGenome(
            body: BodyGene.from(personalityGene: pg),
            eyes: EyeGene.allCases.randomElement()!,
            pattern: PatternGene.allCases.randomElement()!,
            personalityGene: pg,
            seed: UInt32.random(in: UInt32.min...UInt32.max)
        )
    }
}
