import Foundation
import Combine
import CoreGraphics

@MainActor
class PetEngine: ObservableObject {
    @Published var pet: PetState
    @Published var currentAction: PetAction = .idle
    @Published var currentDialogue: String?
    @Published private(set) var renderedGrid: PixelGrid = .empty()
    @Published private(set) var renderedImage: CGImage?
    @Published var physicsState: PetPhysicsState = PetPhysicsState(
        position: CGPoint(x: 60, y: 200), velocity: .zero, surface: .ground)
    @Published var particles: [PetParticle] = []

    private let renderer = PetRenderer()
    private let rendererV2 = PetRendererV2()
    let animator = PetAnimationController()
    private let tracker = InteractionTracker()
    private let dialogEngine = PetDialogEngine()
    private let socialEngine = PetSocialEngine()
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
        updateRenderedGrid()
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
        currentAction = .evolving
        pet.genome.mutate(trigger: .evolution)
        updateRenderedGrid()
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

    private func updateRenderedGrid() {
        renderedGrid = renderer.render(genome: pet.genome, level: pet.level,
                                        mood: pet.mood, animationFrame: animator.currentFrame)
        updateRenderedImage()
    }

    private func setupAnimationObserver() {
        animator.startAnimation()
        animator.$currentFrame
            .sink { [weak self] _ in self?.updateRenderedGrid() }
            .store(in: &cancellables)
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
