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
    @Published var showNamingDialog = false

    struct DroppedFood {
        let type: FoodType
        let position: CGPoint
    }

    @Published var foodTarget: DroppedFood?
    private let feedCooldown: TimeInterval = 1800

    private let rendererV2 = PetRendererV2()
    let animator = PetAnimationController()
    private let tracker = InteractionTracker()
    private let dialogEngine = PetDialogEngine()
    private let socialEngine = PetSocialEngine()
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
        pet.level == .egg ? PetPalettes.egg : PetPalettes.palette(for: pet.genome)
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

    init(pet: PetState = .newEgg()) {
        self.pet = pet
        setupAnimationObserver()
    }

    func handleInteraction(_ type: InteractionType) {
        tracker.record(type)
        pet.experience += type.experienceValue
        pet.mood = tracker.calculateMood(hasSocialRecently: hasSocialRecently)
        pet.lastInteraction = Date()

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
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            finishPooping()
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
    private func checkEvolution() {
        guard let req = EvolutionRequirement.for(pet.level) else { return }
        let age = Date().timeIntervalSince(pet.birthDate)
        let multiplier = hasSocialRecently ? req.socialBonus : 1.0
        let effectiveExp = Double(pet.experience) * multiplier
        if effectiveExp >= Double(req.requiredExperience) && age >= req.minimumAge {
            evolve(to: req.targetLevel)
        }
    }

    private func evolve(to level: PetLevel) {
        pet.level = level
        if level == .baby && (pet.name == nil || pet.name?.isEmpty == true) {
            showNamingDialog = true
        }
        currentAction = .evolving
        // 10% mutation chance on baby→child evolution
        if level == .child && Double.random(in: 0...1) < 0.1 {
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
        let scale = 8
        let pal: ColorPalette = pet.level == .egg ? PetPalettes.egg : PetPalettes.palette(for: pet.genome)
        renderedImage = rendererV2.render(
            genome: pet.genome, level: pet.level, action: currentAction, mood: pet.mood,
            frame: animator.currentFrame, palette: pal, scale: scale,
            facingRight: physicsState.facingRight)
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
