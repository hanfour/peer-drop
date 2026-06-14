import Foundation

// MARK: - Gene Enums

public enum BodyGene: String, Codable, CaseIterable {
    // Core families (most v5-animation coverage).
    case cat, dog, rabbit, bird, frog, bear, dragon, octopus, slime
    // Expansion families unlocked 2026-06-14 — these already had bundled sprites
    // + SpeciesCatalog entries (and even variant-rarity tags like `pig-boar`),
    // but no BodyGene case, so `resolvedSpeciesID` (keyed on `body.rawValue`)
    // could never select them: 71% of bundled assets were unreachable. Adding
    // the cases makes every SpeciesCatalog family hatchable.
    case cow, deer, duck, fox, hamster, hedgehog, horse, lizard, otter, owl
    case parrot, penguin, phoenix, pig, pigeon, raccoon, redpanda, sheep, sloth
    case snake, squirrel, totoro, turtle, unicorn, wolf

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
    public init(from decoder: Decoder) throws {
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
    public static func from(personalityGene pg: Double) -> BodyGene {
        // Weighted hatch distribution over a `pg` in [0, 1). Core families stay
        // common (they have the most v5 walk/idle coverage so they animate);
        // the 25 expansion families are rarer but reachable so their bundled
        // sprites actually appear in the app. Auto-scales as cases are added.
        let p = min(max(pg, 0), 0.999_999)
        let total = allCases.reduce(0.0) { $0 + $1.hatchWeight }
        var threshold = p * total
        for body in allCases {
            threshold -= body.hatchWeight
            if threshold < 0 { return body }
        }
        return .cat
    }

    /// Relative hatch likelihood. Cat dominates (best-tested v5 species); the
    /// other 8 core families are common; the 25 expansion families share a
    /// smaller-but-non-trivial tail (≈1.4% each).
    var hatchWeight: Double {
        switch self {
        case .cat: return 20
        case .dog, .rabbit, .bird, .frog, .bear, .dragon, .octopus, .slime: return 6
        default: return 1.5
        }
    }

    /// User-facing species name. The gene-info UI previously surfaced the
    /// raw rawValue ("cat", "slime") which read like debug output (audit
    /// round 18). Hard-coded zh-Hant台灣用語 to match the module's existing
    /// displayName pattern (PetLevel / PetMood), which has no string catalog.
    public var displayName: String {
        switch self {
        case .cat: return "貓咪"
        case .dog: return "狗狗"
        case .rabbit: return "兔子"
        case .bird: return "小鳥"
        case .frog: return "青蛙"
        case .bear: return "熊熊"
        case .dragon: return "小龍"
        case .octopus: return "章魚"
        case .slime: return "史萊姆"
        case .cow: return "牛牛"
        case .deer: return "鹿鹿"
        case .duck: return "鴨鴨"
        case .fox: return "狐狸"
        case .hamster: return "倉鼠"
        case .hedgehog: return "刺蝟"
        case .horse: return "馬兒"
        case .lizard: return "蜥蜴"
        case .otter: return "水獺"
        case .owl: return "貓頭鷹"
        case .parrot: return "鸚鵡"
        case .penguin: return "企鵝"
        case .phoenix: return "鳳凰"
        case .pig: return "豬豬"
        case .pigeon: return "鴿子"
        case .raccoon: return "浣熊"
        case .redpanda: return "小熊貓"
        case .sheep: return "綿羊"
        case .sloth: return "樹懶"
        case .snake: return "蛇蛇"
        case .squirrel: return "松鼠"
        case .totoro: return "龍貓"
        case .turtle: return "烏龜"
        case .unicorn: return "獨角獸"
        case .wolf: return "狼狼"
        }
    }
}

public enum EyeGene: String, Codable, CaseIterable {
    case dot
    case round
    case line
    case dizzy

    public var displayName: String {
        switch self {
        case .dot: return "豆豆眼"
        case .round: return "圓滾眼"
        case .line: return "瞇瞇眼"
        case .dizzy: return "暈眩眼"
        }
    }
}

public enum LimbGene: String, Codable, CaseIterable {
    case short
    case long
    case none
}

public enum PatternGene: String, Codable, CaseIterable {
    case none
    case stripe
    case spot

    public var displayName: String {
        switch self {
        case .none: return "純色"
        case .stripe: return "條紋"
        case .spot: return "斑點"
        }
    }
}

// MARK: - PersonalityTraits

public struct PersonalityTraits: Codable, Equatable {
    /// 0.0 = clingy, 1.0 = independent
    public var independence: Double
    /// 0.0 = indifferent, 1.0 = very curious
    public var curiosity: Double
    /// 0.0 = lazy, 1.0 = hyperactive
    public var energy: Double
    /// 0.0 = bold, 1.0 = very timid
    public var timidity: Double
    /// 0.0 = well-behaved, 1.0 = chaotic
    public var mischief: Double

    public init(independence: Double, curiosity: Double, energy: Double, timidity: Double, mischief: Double) {
        self.independence = independence; self.curiosity = curiosity; self.energy = energy
        self.timidity = timidity; self.mischief = mischief
    }

    /// Clamps all trait values to the 0.0~1.0 range.
    public mutating func clamp() {
        independence = min(max(independence, 0.0), 1.0)
        curiosity = min(max(curiosity, 0.0), 1.0)
        energy = min(max(energy, 0.0), 1.0)
        timidity = min(max(timidity, 0.0), 1.0)
        mischief = min(max(mischief, 0.0), 1.0)
    }
}

// MARK: - PetGenome

public struct PetGenome: Codable, Equatable {
    public static let canvasSize = 16

    public var paletteIndex: Int {
        let hash = (personalityGene * 137).truncatingRemainder(dividingBy: 1.0)
        return min(Int(hash * 8), 7)
    }

    public var body: BodyGene
    public var eyes: EyeGene
    public var limbs: LimbGene?  // deprecated, kept for migration
    public var pattern: PatternGene
    /// Master personality seed, 0.0~1.0
    public var personalityGene: Double
    /// v4.0: pinned sub-variety string (e.g. "tabby" for body=.cat → "cat-tabby").
    /// Optional: legacy v3.x JSON decodes as nil, then PetStore migration (M7.2)
    /// assigns a default. Once set, takes precedence over the seed-based pick.
    public var subVariety: String?
    /// v4.0: per-pet deterministic seed for sub-variety re-rolls and future
    /// stochastic genome features. Optional: legacy pets get a seed assigned by
    /// PetStore migration (M7.2) via hash(petId + petName).
    public var seed: UInt32?

    public init(body: BodyGene, eyes: EyeGene, limbs: LimbGene? = nil, pattern: PatternGene, personalityGene: Double, subVariety: String? = nil, seed: UInt32? = nil) {
        self.body = body; self.eyes = eyes; self.limbs = limbs; self.pattern = pattern
        self.personalityGene = personalityGene; self.subVariety = subVariety; self.seed = seed
    }

    /// Derives five personality traits from the single personality gene seed.
    public var personalityTraits: PersonalityTraits {
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
    public mutating func mutate(trigger: InteractionType) {
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
    public static func random() -> PetGenome {
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
