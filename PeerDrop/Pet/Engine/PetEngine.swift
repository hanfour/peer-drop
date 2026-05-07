import Foundation
import Combine
import CoreGraphics
import UIKit

@MainActor
class PetEngine: ObservableObject {
    @Published var pet: PetState
    @Published var currentAction: PetAction = .idle
    @Published var currentDialogue: String?
    @Published private(set) var renderedImage: CGImage?
    @Published var physicsState: PetPhysicsState = PetPhysicsState(
        position: CGPoint(x: 60, y: 200), velocity: .zero, surface: .ground)
    @Published var particles: [PetParticle] = []
    @Published var poopState = PoopState()
    @Published var showEvolutionFlash = false

    struct DroppedFood {
        let type: FoodType
        let position: CGPoint
    }

    @Published var foodTarget: DroppedFood?
    private let feedCooldown: TimeInterval = 1800

    private let rendererV3: PetRendererV3
    private let sharedRenderedPet: SharedRenderedPet
    /// Most recently dispatched render task. Cancelled when a new
    /// updateRenderedImage() call comes in so out-of-order completions can't
    /// overwrite renderedImage with a stale frame.
    private var renderTask: Task<Void, Never>?
    let animator = PetAnimationController()
    private let tracker = InteractionTracker()
    private let dialogEngine = PetDialogEngine()
    private let socialEngine = PetSocialEngine()
    private(set) var behaviorProvider: any PetBehaviorProvider
    private let sharedState = SharedPetState()
    private let activityManager: Any? = {
        if #available(iOS 16.2, *) {
            return PetActivityManager()
        }
        return nil
    }()
    private var cancellables = Set<AnyCancellable>()
    private var lastBehaviorDate = Date.distantPast

    var palette: ColorPalette {
        PetPalettes.palette(for: pet.genome)
    }

    var evolutionProgress: Double {
        guard let req = EvolutionRequirement.for(pet.level) else { return 1.0 }
        return min(1.0, Double(pet.experience) / Double(req.requiredExperience))
    }

    var currentLifeState: PetLifeState {
        PetLifeState.current(energy: pet.genome.personalityTraits.energy)
    }

    private var hasSocialRecently: Bool {
        pet.socialLog.contains { Date().timeIntervalSince($0.date) < 86400 }
    }

    init(
        pet: PetState = .newEgg(),
        rendererV3: PetRendererV3? = nil,
        sharedRenderedPet: SharedRenderedPet? = nil
    ) {
        self.pet = pet
        self.behaviorProvider = PetBehaviorProviderFactory.create(for: pet.genome.body)
        // PetRendererV3.init is @MainActor isolated, so we can't put it in a
        // default parameter expression (those evaluate outside isolation).
        // Build it here in the @MainActor init body when no override is given.
        self.rendererV3 = rendererV3 ?? PetRendererV3()
        // SharedRenderedPet bridges to the App Group container so the widget
        // and Live Activity can read the latest rendered pet without re-running
        // the v4.0 PNG pipeline themselves (M8 phase 2 wire-up).
        self.sharedRenderedPet = sharedRenderedPet ?? SharedRenderedPet()
        setupAnimationObserver()
    }

    // MARK: - Daily Login & Rewards

    func checkDailyLogin() {
        let cal = Calendar.current
        if let lastLogin = pet.lastLoginDate, cal.isDateInToday(lastLogin) { return }
        pet.foodInventory.applyDailyRefresh()
        pet.lastLoginDate = Date()
    }

    func onPeerConnected() {
        let randomFood = FoodType.allCases.randomElement()!
        pet.foodInventory.add(randomFood, count: 1)
        pet.stats.petsMet += 1
    }

    /// Minimum seconds between XP-granting taps. Non-tap interactions are not throttled.
    private static let tapCooldown: TimeInterval = 3.0
    /// Max tap XP per day to prevent grinding
    private static let maxDailyTapXP: Int = 50
    private var lastTapDate: Date?

    func handleInteraction(_ type: InteractionType) {
        let now = Date()

        // Throttle taps: cooldown + daily cap
        if type == .tap {
            if let last = lastTapDate, now.timeIntervalSince(last) < Self.tapCooldown {
                // Cooldown active — still animate/mood but no XP
                pet.mood = tracker.calculateMood(hasSocialRecently: hasSocialRecently)
                pet.lastInteraction = now
                updateRenderedImage()
                return
            }
            let todayTapXP = tracker.tapXPToday
            if todayTapXP >= Self.maxDailyTapXP {
                pet.mood = tracker.calculateMood(hasSocialRecently: hasSocialRecently)
                pet.lastInteraction = now
                updateRenderedImage()
                return
            }
            lastTapDate = now
        }

        tracker.record(type)
        pet.experience += type.experienceValue
        pet.mood = tracker.calculateMood(hasSocialRecently: hasSocialRecently)
        pet.lastInteraction = now
        pet.stats.totalInteractions += 1

        // Gene mutation (5% chance)
        if Double.random(in: 0...1) < 0.05 {
            pet.genome.mutate(trigger: type)
        }

        // Try to reveal a secret chat
        if let revealed = socialEngine.tryReveal(pet: pet),
           let idx = pet.socialLog.firstIndex(where: { $0.id == revealed.id }) {
            pet.socialLog[idx].isRevealed = true
            currentDialogue = dialogEngine.generate(level: pet.level, mood: .excited)
        }

        checkEvolution()
        updateRenderedImage()
        syncSharedState()
    }

    func handlePetMeeting(partnerGreeting: PetGreeting) {
        let entry = socialEngine.onPetMeeting(myPet: pet, partnerGreeting: partnerGreeting)
        pet.socialLog.append(entry)
        handleInteraction(.petMeeting)
        currentAction = .love
        for _ in 0..<3 {
            let offset = CGVector(dx: Double.random(in: -20...20), dy: Double.random(in: -30...(-10)))
            particles.append(PetParticle(type: .heart, position: physicsState.position,
                                          velocity: offset, lifetime: 1.0))
        }
    }

    func handleChatMessage() {
        handleInteraction(.chatActive)
        triggerChatBehavior()
    }

    func reactionForEvent(_ event: InteractionType) -> PetAction {
        pet.genome.personalityTraits.reaction(to: event)
    }

    // MARK: - Poop & Stroke

    func cleanPoop(id: UUID) {
        guard poopState.clean(id: id) else { return }
        pet.experience += 1
        pet.stats.poopsCleaned += 1
        if Double.random(in: 0...1) < 0.1 {
            pet.foodInventory.add(.fish, count: 1)
        }
        particles.append(PetParticle(type: .star, position: physicsState.position,
                                      velocity: CGVector(dx: 0, dy: -20), lifetime: 0.8))
        checkEvolution()
        updateRenderedImage()
        syncSharedState()
    }

    func handlePetStroke() {
        pet.experience += 3
        currentAction = .petted
        for _ in 0..<3 {
            let offset = CGVector(dx: Double.random(in: -20...20), dy: Double.random(in: -40...(-10)))
            particles.append(PetParticle(type: .heart, position: physicsState.position,
                                          velocity: offset, lifetime: 1.0))
        }
        checkEvolution()
        updateRenderedImage()
        syncSharedState()
    }

    // MARK: - Feeding

    func dropFood(_ type: FoodType, at position: CGPoint) {
        if let lastFed = pet.lastFedAt, Date().timeIntervalSince(lastFed) < feedCooldown { return }
        guard pet.foodInventory.consume(type) else { return }
        foodTarget = DroppedFood(type: type, position: position)
    }

    func consumeFood() {
        guard let food = foodTarget else { return }
        foodTarget = nil
        pet.experience += food.type.xp
        if let mood = food.type.moodEffect { pet.mood = mood }
        pet.lastFedAt = Date()
        pet.lifeState = .digesting
        let delay = TimeInterval.random(in: food.type.digestMinSeconds...food.type.digestMaxSeconds)
        pet.digestEndTime = Date().addingTimeInterval(delay)
        pet.stats.foodsEaten += 1
        currentAction = .eat
        checkEvolution()
        syncSharedState()
        updateRenderedImage()
    }

    // MARK: - Digestion

    func checkDigestion() {
        guard pet.lifeState == .digesting,
              let end = pet.digestEndTime, Date() >= end else { return }
        pet.lifeState = .pooping
        currentAction = .poop
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.pet.lifeState == .pooping else { return }
            self.finishPooping()
        }
    }

    func finishPooping() {
        poopState.drop(at: physicsState.position)
        pet.lifeState = .idle
        currentAction = .idle
        pet.digestEndTime = nil
    }

    // MARK: - Chat-aware behavior
    private func triggerChatBehavior() {
        let now = Date()
        guard now.timeIntervalSince(lastBehaviorDate) > 30 else { return } // 30s cooldown
        lastBehaviorDate = now
        let traits = pet.genome.personalityTraits
        currentAction = traits.reaction(to: .chatActive)
        let dismissDelay: TimeInterval = currentAction == .blockText ? 10.0 : 3.0
        Task {
            try? await Task.sleep(nanoseconds: UInt64(dismissDelay * 1_000_000_000))
            currentAction = .idle
        }
    }

    // MARK: - Evolution
    //
    // v4.0.1 lifecycle model (egg stage removed):
    //   baby  → adult  : age-only at 8 days from birthDate (was: 3 days + 500 XP in v3.x)
    //   adult → elder  : age-only at 14 days from birthDate (new in v4.0)
    //   elder          : terminal
    //
    // The baby→adult shift from experience-driven to age-only is intentional: v4.0
    // emphasises graceful aging over grinding. Legacy pets that were stuck at .baby
    // with insufficient XP will simply age into .adult on the first interaction
    // after their 8-day mark.
    private func checkEvolution() {
        // FIXME(v4.0.x): EvolutionRequirement.for(.baby) thresholds (500 XP / 3 days) don't match checkEvolution()'s age-only 8-day rule. UI evolutionProgress + PetTabView "ready in ~Xh" hint will mislead users. Refactor in v4.0.x polish.
        let ageInDays = Date().timeIntervalSince(pet.birthDate) / 86400

        switch pet.level {
        case .baby:
            if ageInDays >= 8 { evolve(to: .adult) }
        case .adult:
            if ageInDays >= 14 { evolve(to: .elder) }
        case .elder:
            return
        }
    }

    private func evolve(to level: PetLevel) {
        pet.level = level
        // Naming UX moved to PetWelcomeView (Phase 4) — pets are born .baby, not evolved into it.
        currentAction = .evolving
        // 10% mutation chance on baby→adult evolution
        if level == .adult && Double.random(in: 0...1) < 0.1 {
            pet.genome.mutate(trigger: .evolution)
        }
        // Spawn 5 star particles
        for _ in 0..<5 {
            let vel = CGVector(dx: Double.random(in: -30...30), dy: Double.random(in: -50...(-10)))
            particles.append(PetParticle(type: .star, position: physicsState.position,
                                          velocity: vel, lifetime: 1.2))
        }
        updateRenderedImage()

        showEvolutionFlash = true
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            showEvolutionFlash = false
        }
    }

    // MARK: - Rendering
    func updateRenderedImage() {
        // V3 path: PNG sprite via SpriteService + mood SF Symbol overlay.
        // SpriteService is an actor, so the call is async and dispatched as a
        // Task. We cancel any in-flight Task before queuing the next one —
        // otherwise rapid facingRight flips (or evolution + interaction in
        // the same frame) could see a slow earlier render complete after a
        // fast later one and overwrite renderedImage with a stale frame.
        //
        // The animator-driven per-frame trigger is preserved — repeated calls
        // with the same arguments hit the SpriteService cache cheaply, and
        // PetRendererV3's own composite memoization (M4 fix) skips the
        // UIGraphicsImageRenderer pass when the inputs haven't changed.
        let genome = pet.genome
        let level = pet.level
        let mood = pet.mood
        let direction: SpriteDirection = physicsState.facingRight ? .east : .west

        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self, rendererV3, sharedRenderedPet] in
            let img = try? await rendererV3.render(
                genome: genome, level: level, mood: mood, direction: direction)
            // If a newer updateRenderedImage() call cancelled us between the
            // await and resumption, drop this frame on the floor.
            guard !Task.isCancelled else { return }
            self?.renderedImage = img
            // Mirror the rendered image into the App Group container so the
            // widget + Live Activity (which can't run the PNG pipeline
            // themselves) display the same frame the host app sees. nil
            // images (assetNotFound, ghost pets, missing-stage) intentionally
            // skip the write — the widget falls back to its placeholder.
            if let img = img {
                sharedRenderedPet.write(img)
            }
        }
    }

    private func setupAnimationObserver() {
        animator.startAnimation()
        animator.$currentFrame
            .sink { [weak self] _ in self?.updateRenderedImage() }
            .store(in: &cancellables)
    }

    // MARK: - Shared State & Live Activity

    func syncSharedState() {
        let snapshot = PetSnapshot(
            name: pet.name,
            bodyType: pet.genome.body,
            eyeType: pet.genome.eyes,
            patternType: pet.genome.pattern,
            level: pet.level,
            mood: pet.mood,
            paletteIndex: pet.genome.paletteIndex,
            experience: pet.experience,
            maxExperience: EvolutionRequirement.for(pet.level)?.requiredExperience ?? 999
        )
        sharedState.write(snapshot)
        if #available(iOS 16.2, *) {
            (activityManager as? PetActivityManager)?.updateActivity(snapshot: snapshot)
        }
    }

    func startLiveActivity() {
        guard #available(iOS 16.2, *) else { return }
        let snapshot = PetSnapshot(
            name: pet.name,
            bodyType: pet.genome.body,
            eyeType: pet.genome.eyes,
            patternType: pet.genome.pattern,
            level: pet.level,
            mood: pet.mood,
            paletteIndex: pet.genome.paletteIndex,
            experience: pet.experience,
            maxExperience: EvolutionRequirement.for(pet.level)?.requiredExperience ?? 999
        )
        (activityManager as? PetActivityManager)?.startActivity(snapshot: snapshot)
    }

    func endLiveActivity() {
        guard #available(iOS 16.2, *) else { return }
        (activityManager as? PetActivityManager)?.endActivity()
    }
}

// MARK: - PersonalityTraits reaction mapping
extension PersonalityTraits {
    func reaction(to event: InteractionType) -> PetAction {
        switch event {
        case .tap:
            if independence > 0.7 { return .ignore }
            if timidity > 0.7 { return .freeze }
            return .wagTail
        case .shake:
            if timidity > 0.5 { return .hideInShell }
            if energy > 0.7 { return .zoomies }
            return .idle
        case .fileTransfer:
            if energy > 0.5 { return .stuffCheeks }
            return .idle
        case .chatActive:
            if curiosity > 0.7 { return .tiltHead }
            if mischief > 0.7 { return .climbOnBubble }
            return .notifyMessage
        case .peerConnected:
            return .wagTail
        default:
            return .idle
        }
    }
}

// MARK: - Time-of-Day Behavior

enum PetTimeOfDayBehavior {
    static func suggestedMood(at date: Date = Date(), lastInteraction: Date) -> PetMood? {
        let hour = Calendar.current.component(.hour, from: date)
        let isNight = hour >= 22 || hour < 6
        let recentlyInteracted = date.timeIntervalSince(lastInteraction) < 1800
        if isNight && !recentlyInteracted {
            return .sleepy
        }
        return nil
    }
}
