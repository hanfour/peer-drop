import Foundation
import Combine
import CoreGraphics
import OSLog
import UIKit

private let petEngineLog = Logger(subsystem: "com.hanfour.peerdrop", category: "PetEngine")

@MainActor
class PetEngine: ObservableObject {
    @Published var pet: PetState {
        didSet {
            // `behaviorProvider` is keyed off `pet.genome.body`. PeerDropApp
            // constructs `PetEngine()` with a random `newEgg()`, then later
            // assigns `petEngine.pet = saved` (or the screenshot mock) — that
            // path needs to also swap the behavior provider, otherwise (for
            // example) a saved cat ends up driven by a random dog/bear/frog
            // provider chosen at init time. Recreating only on body change is
            // a no-op for hatched pets in normal play (body is immutable).
            if oldValue.genome.body != pet.genome.body {
                behaviorProvider = PetBehaviorProviderFactory.create(for: pet.genome.body)
            }
        }
    }
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
    private let spriteService: SpriteService
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

    /// Progress toward the next evolution, in [0, 1]. v5.0.x: age-based to
    /// match `checkEvolution()`'s actual rule (8 days for baby→adult, 90 days
    /// for adult→elder). Pre-v5.0.x this was XP-based against thresholds the
    /// engine never enforced — see `EvolutionRequirement` doc comment.
    /// Elder pets return 1.0 (final stage).
    var evolutionProgress: Double {
        guard let req = EvolutionRequirement.for(pet.level), req.minimumAge > 0 else { return 1.0 }
        let elapsed = Date().timeIntervalSince(pet.birthDate)
        return min(1.0, max(0.0, elapsed / req.minimumAge))
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
        sharedRenderedPet: SharedRenderedPet? = nil,
        spriteService: SpriteService = .shared
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
        // v5: dispatchActionToAnimator probes SpriteService for animation
        // metadata. Tests inject a SpriteService bound to the test bundle so
        // hand-crafted fixtures (whose species aren't in SpeciesCatalog) can
        // exercise the metadata-fetch path; production uses .shared.
        self.spriteService = spriteService
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
    // v5.0 lifecycle model (corrects v4.0.x's overly-rapid aging):
    //   baby  → adult  : age-only at 8 days from birthDate
    //   adult → elder  : age >= 90 days AND interacted within last 30 days
    //   elder          : terminal (set during the active engagement window)
    //
    // Why the change from v4.0.x's 14-day adult→elder gate:
    // 14 days meant adult was a 6-day blip and any user past 2 weeks had a
    // permanently-elder pet. Two corrections:
    //   1. Stretch baseline timeline. 90 days lets adult be the dominant
    //      stage (~3 months) with elder as a genuine "your pet has lived a
    //      long life" milestone.
    //   2. Activity gate. Pets only progress to elder if their owner is
    //      actively engaging — dormant pets stay adult. A user returning
    //      after a long absence finds their pet still adult (their
    //      lastInteraction is stale, so the gate doesn't fire). Once they
    //      resume interacting, lastInteraction updates and the gate
    //      evaluates against the new reality.
    //
    // Migration (one-shot, see migrateAgingForV5): existing pets that were
    // incorrectly promoted to elder under the old gate get demoted back to
    // adult at first v5 launch.
    static let adultToElderAgeDays: Double = 90
    static let adultToElderActivityWindowDays: Double = 30

    private func checkEvolution() {
        // FIXME(v5.x): EvolutionRequirement.for(.baby) thresholds (500 XP / 3 days) don't match checkEvolution()'s age-only 8-day rule. UI evolutionProgress + PetTabView "ready in ~Xh" hint will mislead users. Refactor in v5.x polish.
        let now = Date()
        let ageInDays = now.timeIntervalSince(pet.birthDate) / 86400

        switch pet.level {
        case .baby:
            if ageInDays >= 8 { evolve(to: .adult) }
        case .adult:
            // Both gates required: meaningful age AND ongoing engagement.
            let daysSinceInteraction = now.timeIntervalSince(pet.lastInteraction) / 86400
            if ageInDays >= Self.adultToElderAgeDays
                && daysSinceInteraction < Self.adultToElderActivityWindowDays {
                evolve(to: .elder)
            }
        case .elder:
            return
        }
    }

    /// One-shot v5 migration: pets that were promoted to .elder under the
    /// pre-v5 14-day age-only gate but don't meet the v5 90-day + activity
    /// gate get demoted back to .adult. Idempotent — re-runs are no-ops
    /// because demoted pets either qualify for re-promotion next tick (in
    /// which case they correctly become elder again) or stay adult.
    ///
    /// Called once per device on first v5 launch from PeerDropApp .task,
    /// gated alongside the renderedImageVersion bump so it can't run
    /// repeatedly. Public so PeerDropApp can invoke it.
    /// Returns true iff a demotion happened (for logging / migration record).
    @discardableResult
    func migrateAgingForV5() -> Bool {
        guard pet.level == .elder else { return false }
        let now = Date()
        let ageInDays = now.timeIntervalSince(pet.birthDate) / 86400
        let daysSinceInteraction = now.timeIntervalSince(pet.lastInteraction) / 86400
        let qualifiesUnderV5 = ageInDays >= Self.adultToElderAgeDays
            && daysSinceInteraction < Self.adultToElderActivityWindowDays
        if !qualifiesUnderV5 {
            // os_log so the migration is visible in Console.app's unified
            // logging without spamming the runtime. Operator can confirm the
            // fix landed on a real device by filtering Console for category
            // "PetEngine" and seeing this line on first v5 launch.
            petEngineLog.notice("v5 aging migration: demoting elder→adult — ageInDays=\(ageInDays, privacy: .public), daysSinceInteraction=\(daysSinceInteraction, privacy: .public)")
            pet.level = .adult
            return true
        }
        petEngineLog.debug("v5 aging migration: keeping elder — qualifies under v5 (ageInDays=\(ageInDays, privacy: .public), daysSinceInteraction=\(daysSinceInteraction, privacy: .public))")
        return false
    }

    /// One-shot v5.0.1 migration: force-persist current state so any pet whose
    /// persisted JSON had `body: "ghost"` (silently mapped to `.cat` by
    /// `BodyGene.init(from:)` at load time) writes the corrected body back to
    /// disk immediately, ahead of the next backgrounding event. Without this,
    /// a user who never backgrounds the app between launches would keep the
    /// stale `body: "ghost"` JSON on disk indefinitely — the runtime works
    /// correctly via the decoder shim, but the disk state stays inconsistent.
    /// Idempotent — safe to call repeatedly; subsequent calls just re-write
    /// the already-cat body. Returns true on successful persist.
    @discardableResult
    func migrateGhostBodyForV501() -> Bool {
        do {
            try PetStore().save(pet)
            petEngineLog.notice("v5.0.1 ghost migration: persisted current pet state — body=\(self.pet.genome.body.rawValue, privacy: .public)")
            return true
        } catch {
            petEngineLog.error("v5.0.1 ghost migration: persist failed — \(error.localizedDescription, privacy: .public)")
            return false
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
        // v5: PNG sprite via SpriteService + mood SF Symbol overlay,
        // multi-frame animated. Calls the renderer's v5 overload with the
        // animator's currentAction + currentFrame so each animator tick
        // produces a different frame. v4-format zips (no animations block)
        // are handled by SpriteService's graceful 1-frame fallback, so this
        // path doesn't need to special-case them.
        //
        // SpriteService is an actor, so the call is async and dispatched as a
        // Task. We cancel any in-flight Task before queuing the next one —
        // otherwise rapid facingRight flips (or evolution + interaction in
        // the same frame) could see a slow earlier render complete after a
        // fast later one and overwrite renderedImage with a stale frame.
        let genome = pet.genome
        let level = pet.level
        let mood = pet.mood
        let direction: SpriteDirection = physicsState.facingRight ? .east : .west
        let action = animator.currentAction
        let frameIndex = animator.currentFrame

        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self, rendererV3, sharedRenderedPet] in
            let img = try? await rendererV3.render(
                genome: genome,
                level: level,
                direction: direction,
                action: action,
                frameIndex: frameIndex,
                mood: mood)
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

    /// Velocity magnitude (px/s) ABOVE which idle promotes to walking.
    /// Tuned to ignore sub-pixel residuals from physics integration
    /// (throwDecay leaves tiny dx after the pet appears stopped).
    static let walkEnterThreshold: Double = 5.0

    /// Velocity magnitude (px/s) BELOW which walking demotes back to idle.
    /// Lower than the enter threshold to give hysteresis around the bound:
    /// without the gap, a velocity that oscillates near 5.0 (e.g. friction
    /// damping a throw) would flap walk→idle→walk every physics tick,
    /// each transition spawning a fresh Task in dispatchActionToAnimator.
    static let walkExitThreshold: Double = 3.0

    /// Maps (previous action, current velocity) to the next v5 PetAction
    /// using a hysteresis band: walking only exits below 3.0 px/s; idle
    /// only enters walk above 5.0 px/s. Pure function for unit testing.
    static func nextAction(previous: PetAction, velocity: CGVector) -> PetAction {
        let speed = hypot(Double(velocity.dx), Double(velocity.dy))
        switch previous {
        case .walking:
            return speed >= walkExitThreshold ? .walking : .idle
        default:
            return speed > walkEnterThreshold ? .walking : .idle
        }
    }

    /// Stateless variant retained for unit tests of the simple threshold
    /// case (the integration tests exercise the hysteresis path via the
    /// engine pipeline below). Treats the caller as starting from idle.
    static func actionFromVelocity(_ velocity: CGVector) -> PetAction {
        return nextAction(previous: .idle, velocity: velocity)
    }

    private func setupAnimationObserver() {
        animator.startAnimation()

        // Each animator tick triggers a re-render so the new frameIndex
        // reaches the renderer.
        animator.$currentFrame
            .sink { [weak self] _ in self?.updateRenderedImage() }
            .store(in: &cancellables)

        // Drive the sprite animator off engine.currentAction directly.
        //
        // The earlier velocity-driven `$physicsState.scan(...).removeDuplicates`
        // pipeline assumed `applyWalk` would set `state.velocity` to the
        // walking velocity — but applyWalk is kinematic (modifies position
        // directly, leaves velocity at .zero). So the pipeline only ever saw
        // velocity = 0, always emitted `.idle`, and removeDuplicates filtered
        // every subsequent emission. The animator stayed locked in its
        // default `.idle` action regardless of what the behavior loop set,
        // which surfaced as "the cat slides across the screen but the legs
        // don't cycle" (Phase 3 visual verification, 2026-05-12).
        //
        // currentAction is the actual source of truth — set by the behavior
        // loop, drag/throw handlers, and food-chase logic — so observing it
        // directly puts the animator in sync with what physicsStep is doing.
        // removeDuplicates() guards against redundant emissions; the
        // animator's own same-action guard in setAction(_:frameCount:fps:)
        // double-guards against frame resets on direction flips.
        $currentAction
            .removeDuplicates()
            .sink { [weak self] action in self?.dispatchActionToAnimator(action) }
            .store(in: &cancellables)
    }

    /// Resolves the metadata-defined frameCount + fps for `action` on the
    /// pet's species/stage and rebinds the animator. v4-format zips (no
    /// animations block) and unsupported actions both fall back to a single
    /// 1-frame loop — animator still ticks, renderer's frameIndex stays at
    /// 0, render output stays static.
    private func dispatchActionToAnimator(_ action: PetAction) {
        guard action.animationKey != nil else {
            animator.setAction(action, frameCount: 1, fps: 1)
            return
        }
        Task { [weak self] in
            // Re-snapshot species + stage INSIDE the Task rather than
            // capturing them at scheduling time. If the pet evolves
            // (baby -> adult) between physicsState velocity emit and Task
            // resumption — which can be many physics ticks later under
            // load — we'd otherwise bind the animator with the previous
            // stage's frame count and the renderer would read the new
            // stage's frames. (`safeIndex` in PetRendererV3 defends against
            // the residual await-during-evolution race by wrapping
            // out-of-bounds frameIndex to 0; this fix narrows the window.)
            guard let species = self?.pet.genome.resolvedSpeciesID,
                  let stage = self?.pet.level else { return }
            let request = AnimationRequest(
                species: species, stage: stage, direction: .south, action: action)
            do {
                let service = self?.spriteService ?? .shared
                let frames = try await service.frames(for: request)
                self?.animator.setAction(action, frameCount: frames.images.count, fps: frames.fps)
            } catch {
                self?.animator.setAction(action, frameCount: 1, fps: 1)
            }
        }
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
            evolutionProgress: evolutionProgress
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
            evolutionProgress: evolutionProgress
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
