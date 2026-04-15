import SwiftUI

struct FloatingPetView: View {
    @ObservedObject var engine: PetEngine
    @State private var isDragging = false
    @State private var showInteractionPanel = false
    @State private var dragStartPosition: CGPoint = .zero
    @State private var dragStartTime: Date = .init()
    @State private var lastDragPosition: CGPoint = .zero
    @State private var displayLink: CADisplayLink?
    @State private var behaviorTimer: Timer?
    @State private var behaviorElapsed: TimeInterval = 0
    @State private var namingText = ""
    @State private var isAbsent = false           // pet has left the screen
    @State private var isExiting = false          // currently playing exit animation
    @State private var isEntering = false         // currently playing enter animation
    @State private var exitScale: CGFloat = 1.0   // current scale during exit/enter
    @State private var exitOpacity: CGFloat = 1.0 // current opacity during exit/enter
    @State private var idleSinceDate: Date?       // tracks how long pet has been idle

    private let displaySize: CGFloat = 128

    var body: some View {
        ZStack {
            // Dropped food
            if let food = engine.foodTarget {
                Text(food.type.emoji)
                    .font(.system(size: 24))
                    .position(food.position)
            }

            // Poops
            ForEach(engine.poopState.poops) { poop in
                Text("💩")
                    .font(.system(size: 20))
                    .position(poop.position)
                    .onTapGesture {
                        engine.cleanPoop(id: poop.id)
                    }
            }

            // Particles behind pet
            ForEach(engine.particles) { particle in
                PetParticleView(particle: particle)
                    .position(particle.position)
            }

            ZStack {
                SpriteImageView(image: engine.renderedImage, displaySize: displaySize)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

                if let dialogue = engine.currentDialogue {
                    PetBubbleView(text: dialogue)
                        .offset(y: -72)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(exitScale)
            .opacity(exitOpacity)
            .position(engine.physicsState.position)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !isAbsent && !isExiting && !isEntering else { return }
                        if !isDragging {
                            isDragging = true
                            dragStartPosition = engine.physicsState.position
                            dragStartTime = Date()
                            engine.currentAction = .pickedUp
                        }
                        lastDragPosition = engine.physicsState.position
                        engine.physicsState.position = value.location
                        engine.physicsState.surface = .airborne
                        engine.physicsState.velocity = .zero
                    }
                    .onEnded { value in
                        guard !isAbsent && !isExiting && !isEntering else { return }
                        isDragging = false
                        let dt = max(0.016, Date().timeIntervalSince(dragStartTime))
                        let vx = (value.location.x - dragStartPosition.x) / dt * 0.1
                        let vy = (value.location.y - dragStartPosition.y) / dt * 0.1
                        let throwVelocity = CGVector(dx: clamp(vx, -600, 600),
                                                     dy: clamp(vy, -600, 600))
                        PetPhysicsEngine.applyThrow(&engine.physicsState, velocity: throwVelocity)
                        engine.currentAction = .thrown
                        engine.handleInteraction(.tap)
                        behaviorElapsed = 0
                    }
            )
            .onTapGesture {
                guard !isAbsent && !isExiting && !isEntering else { return }
                engine.handleInteraction(.tap)
                engine.currentAction = .tapReact
                behaviorElapsed = 0
                idleSinceDate = nil
            }
            .onLongPressGesture {
                showInteractionPanel = true
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard !isDragging else { return }
                        let hVel = abs(value.velocity.width)
                        let vVel = abs(value.velocity.height)
                        if hVel > vVel && hVel > 200 {
                            engine.handlePetStroke()
                        }
                    }
            )
            if isAbsent {
                Text("\(engine.pet.name ?? "寵物") 出去散步了")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .position(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height - 100)
            }
            if engine.showEvolutionFlash {
                Color.white
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showInteractionPanel) {
            PetInteractionView(engine: engine)
        }
        .dropDestination(for: String.self) { items, location in
            guard let raw = items.first, let foodType = FoodType(rawValue: raw) else { return false }
            engine.dropFood(foodType, at: location)
            return true
        }
        .alert("幫寵物取個名字吧！", isPresented: $engine.showNamingDialog) {
            TextField("名字", text: $namingText)
            Button("確定") {
                let trimmed = namingText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { engine.pet.name = trimmed }
            }
        } message: {
            Text("你的寵物剛孵化了！")
        }
        .accessibilityIdentifier("floating-pet")
        .accessibilityLabel("Pet")
        .onAppear {
            startPhysicsLoop()
            startBehaviorLoop()
        }
        .onDisappear {
            displayLink?.invalidate()
            behaviorTimer?.invalidate()
        }
    }

    // MARK: - Physics Loop

    private func startPhysicsLoop() {
        let target = DisplayLinkTarget { [weak engine] dt in
            guard engine != nil else { return }
            Task { @MainActor in
                self.physicsStep(dt: CGFloat(dt))
            }
        }
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func physicsStep(dt: CGFloat) {
        guard !isDragging else { return }
        guard !isAbsent else { return }
        guard !isExiting && !isEntering else { return }  // animation handles movement
        let surfaces = screenSurfaces()
        let profile = engine.behaviorProvider.profile

        // Chase food target
        if let food = engine.foodTarget {
            let dx = food.position.x - engine.physicsState.position.x
            let dy = food.position.y - engine.physicsState.position.y
            let dist = hypot(dx, dy)
            if dist < 8 {
                engine.consumeFood()
            } else {
                let direction: PetPhysicsEngine.HorizontalDirection = dx > 0 ? .right : .left
                PetPhysicsEngine.applyWalk(&engine.physicsState, direction: direction,
                                           speed: profile.baseSpeed * 1.5, dt: dt, surfaces: surfaces)
            }
        }

        switch engine.currentAction {
        case .walking:
            let direction: PetPhysicsEngine.HorizontalDirection = engine.physicsState.facingRight ? .right : .left
            switch profile.movementStyle {
            case .walk, .slither:
                PetPhysicsEngine.applyWalk(&engine.physicsState, direction: direction,
                                           speed: profile.baseSpeed, dt: dt, surfaces: surfaces)
            case .hop:
                if engine.physicsState.surface == .ground {
                    PetPhysicsEngine.applyHop(&engine.physicsState, direction: direction,
                                              speed: profile.baseSpeed)
                }
            case .fly:
                let flyDir = CGVector(dx: direction == .right ? 1 : -1,
                                      dy: CGFloat.random(in: -0.3...0.3))
                PetPhysicsEngine.applyFly(&engine.physicsState, direction: flyDir,
                                          speed: profile.baseSpeed, dt: dt, surfaces: surfaces)
            case .float:
                let floatDir = CGVector(dx: direction == .right ? 1 : -1,
                                        dy: CGFloat.random(in: -0.3...0.3))
                PetPhysicsEngine.applyFloat(&engine.physicsState, direction: floatDir,
                                            speed: profile.baseSpeed, dt: dt)
            case .bounce:
                if engine.physicsState.surface == .ground {
                    PetPhysicsEngine.applyBounce(&engine.physicsState)
                }
            }

        case .run:
            if engine.foodTarget == nil {
                let direction: PetPhysicsEngine.HorizontalDirection = engine.physicsState.facingRight ? .right : .left
                PetPhysicsEngine.applyWalk(&engine.physicsState, direction: direction,
                                           speed: profile.baseSpeed * 1.3, dt: dt, surfaces: surfaces)
            }

        case .climb:
            PetPhysicsEngine.applyClimb(&engine.physicsState, speed: 40, dt: dt, surfaces: surfaces)

        case .thrown, .fall:
            PetPhysicsEngine.update(&engine.physicsState, dt: dt, surfaces: surfaces, profile: profile)
            if engine.physicsState.surface != .airborne {
                engine.currentAction = .idle
                behaviorElapsed = 0
            }

        // Flying-specific actions
        case .glide, .dive, .hover:
            let flyDir = CGVector(dx: engine.physicsState.facingRight ? 1 : -1,
                                  dy: engine.currentAction == .dive ? 0.5 : -0.2)
            PetPhysicsEngine.applyFly(&engine.physicsState, direction: flyDir,
                                      speed: profile.baseSpeed, dt: dt, surfaces: surfaces)

        // Floating-specific actions (ghost)
        case .phaseThrough:
            let floatDir = CGVector(dx: engine.physicsState.facingRight ? 1 : -1, dy: 0)
            PetPhysicsEngine.applyFloat(&engine.physicsState, direction: floatDir,
                                        speed: profile.baseSpeed, dt: dt)

        default:
            break
        }

        // Let provider do custom physics modifications
        engine.behaviorProvider.modifyPhysics(&engine.physicsState, deltaTime: dt, surfaces: surfaces)

        // Remove expired particles
        engine.particles.removeAll { $0.isExpired }
    }

    // MARK: - Behavior Loop

    private func startBehaviorLoop() {
        behaviorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard !isDragging else { return }
                guard !isAbsent && !isExiting && !isEntering else { return }
                behaviorElapsed += 1.0

                // Track idle time for exit trigger
                if engine.currentAction == .idle {
                    if idleSinceDate == nil {
                        idleSinceDate = Date()
                    }
                    // Trigger exit after 30-60s of idle (influenced by independence)
                    if let since = idleSinceDate {
                        let independence = engine.pet.genome.personalityTraits.independence
                        let exitThreshold: TimeInterval = 60 - (independence * 30) // 30-60s
                        if Date().timeIntervalSince(since) > exitThreshold {
                            triggerExit()
                            idleSinceDate = nil
                            return
                        }
                    }
                } else {
                    idleSinceDate = nil
                }

                if let forcedMood = PetTimeOfDayBehavior.suggestedMood(
                    lastInteraction: engine.pet.lastInteraction) {
                    engine.pet.mood = forcedMood
                }

                engine.checkDigestion()

                let nextAction = engine.behaviorProvider.nextBehavior(
                    current: engine.currentAction,
                    physics: engine.physicsState,
                    level: engine.pet.level,
                    elapsed: behaviorElapsed,
                    foodTarget: engine.foodTarget?.position,
                    traits: engine.pet.genome.personalityTraits)

                if nextAction != engine.currentAction {
                    engine.currentAction = nextAction
                    behaviorElapsed = 0

                    // Flip direction randomly when starting to walk
                    if nextAction == .walking {
                        engine.physicsState.facingRight = Bool.random()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func screenSurfaces() -> ScreenSurfaces {
        let screen = UIScreen.main.bounds
        return ScreenSurfaces(
            ground: screen.height - 80,
            ceiling: 60,
            leftWall: 20,
            rightWall: screen.width - 20,
            dynamicIslandRect: CGRect(x: screen.width / 2 - 62, y: 0, width: 124, height: 37)
        )
    }

    private func clamp(_ value: CGFloat, _ minVal: CGFloat, _ maxVal: CGFloat) -> CGFloat {
        min(max(value, minVal), maxVal)
    }

    // MARK: - Exit/Enter Animation

    private func triggerExit() {
        guard !isExiting && !isAbsent && !isEntering else { return }
        isExiting = true

        let screen = UIScreen.main.bounds
        let sequence = engine.behaviorProvider.exitSequence(
            from: engine.physicsState.position,
            screenBounds: screen)

        playAnimationSequence(sequence.steps, index: 0) {
            // Animation complete — pet is now absent
            isExiting = false
            isAbsent = true
            exitScale = 1.0
            exitOpacity = 1.0

            // Schedule return after 15-45 seconds
            let returnDelay = TimeInterval.random(in: 15...45)
            DispatchQueue.main.asyncAfter(deadline: .now() + returnDelay) {
                triggerEnter()
            }
        }
    }

    private func triggerEnter() {
        guard isAbsent else { return }
        isAbsent = false
        isEntering = true

        let screen = UIScreen.main.bounds
        let sequence = engine.behaviorProvider.enterSequence(screenBounds: screen)

        // Set initial state for enter animation
        exitScale = sequence.steps.first?.scaleDelta.map { 1.0 + $0 } ?? 1.0
        exitOpacity = 0.0

        // Position pet at a reasonable entry point
        let entryX = Bool.random() ? screen.width * 0.2 : screen.width * 0.8
        engine.physicsState.position = CGPoint(x: entryX, y: screen.height - 80)

        playAnimationSequence(sequence.steps, index: 0) {
            isEntering = false
            exitScale = 1.0
            exitOpacity = 1.0
            behaviorElapsed = 0
            idleSinceDate = nil
        }
    }

    private func playAnimationSequence(_ steps: [PetAnimationStep], index: Int, completion: @escaping () -> Void) {
        guard index < steps.count else {
            completion()
            return
        }

        let step = steps[index]
        engine.currentAction = step.action

        withAnimation(.easeInOut(duration: step.duration)) {
            if let scale = step.scaleDelta {
                exitScale += scale
            }
            if let opacity = step.opacityDelta {
                exitOpacity += opacity
            }
            if let posDelta = step.positionDelta {
                engine.physicsState.position.x += posDelta.x
                engine.physicsState.position.y += posDelta.y
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + step.duration) {
            playAnimationSequence(steps, index: index + 1, completion: completion)
        }
    }
}

// MARK: - CADisplayLink Target

private class DisplayLinkTarget {
    let update: (TimeInterval) -> Void
    init(update: @escaping (TimeInterval) -> Void) { self.update = update }
    @objc func tick(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        update(max(dt, 1.0 / 120.0))
    }
}
