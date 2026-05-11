import Foundation

// MARK: - Gene Enums

enum BodyGene: String, Codable, CaseIterable {
    case cat, dog, rabbit, bird, frog, bear, dragon, octopus, slime

    /// Map legacy values from earlier genome saves.
    ///
    /// **v5.0.1 ghost retirement (2026-05-11):** the `.ghost` case was
    /// removed because the species' visual quality never reached an
    /// acceptable bar. Existing pets whose persisted JSON has
    /// `body: "ghost"` silently decode to `.cat`, preserving the pet's
    /// identity (id, name, age, level, interaction history) and only
    /// swapping the rendered appearance. The widget-bridge invalidation
    /// + persist happen in `PetEngine.migrateGhostBodyForV501()` so
    /// disk + widget cache catch up on first launch.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "round": self = .bear
        case "square": self = .cat
        case "oval": self = .slime
        case "ghost": self = .cat
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
    /// **v5.0.1 distribution (2026-05-11):** the 10% ghost band collapses
    /// into cat, raising cat to 50%. Cat-tabby is the only species
    /// shipping at v5 schema (multi-frame walk animations); other species
    /// gain animations across subsequent v5.0.x updates per
    /// `docs/release/v5.0.x-cadence.md`. As more species reach v5 schema,
    /// rebalance back toward uniform.
    static func from(personalityGene pg: Double) -> BodyGene {
        switch pg {
        case ..<0.50: return .cat       // 50% (v5 animated)
        case ..<0.60: return .dog       // 10%
        case ..<0.68: return .rabbit    // 8%
        case ..<0.76: return .bird      // 8%
        case ..<0.82: return .frog      // 6%
        case ..<0.88: return .bear      // 6%
        case ..<0.92: return .dragon    // 4%
        case ..<0.96: return .octopus   // 4%
        default:      return .slime     // 4%
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
