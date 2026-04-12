import SwiftUI

struct FloatingPetView: View {
    @ObservedObject var engine: PetEngine
    @State private var isDragging = false
    @State private var showInteractionPanel = false
    @State private var dragStartPosition: CGPoint = .zero
    @State private var dragStartTime: Date = .init()
    @State private var lastDragPosition: CGPoint = .zero
    @State private var physicsTimer: Timer?
    @State private var behaviorTimer: Timer?
    @State private var behaviorElapsed: TimeInterval = 0

    private let displaySize: CGFloat = 128

    var body: some View {
        ZStack {
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
            .position(engine.physicsState.position)
            .gesture(
                DragGesture()
                    .onChanged { value in
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
                engine.handleInteraction(.tap)
                engine.currentAction = .tapReact
                behaviorElapsed = 0
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
        .accessibilityIdentifier("floating-pet")
        .accessibilityLabel("Pet")
        .onAppear {
            startPhysicsLoop()
            startBehaviorLoop()
        }
        .onDisappear {
            physicsTimer?.invalidate()
            behaviorTimer?.invalidate()
        }
    }

    // MARK: - Physics Loop

    private func startPhysicsLoop() {
        let surfaces = screenSurfaces()
        physicsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in
                guard !isDragging else { return }
                let dt: CGFloat = 1.0 / 60.0

                switch engine.currentAction {
                case .walking:
                    let direction: PetPhysicsEngine.HorizontalDirection = engine.physicsState.facingRight ? .right : .left
                    PetPhysicsEngine.applyWalk(&engine.physicsState, direction: direction,
                                               speed: 60, dt: dt, surfaces: surfaces)
                case .climb:
                    PetPhysicsEngine.applyClimb(&engine.physicsState, speed: 40,
                                                dt: dt, surfaces: surfaces)
                case .thrown, .fall:
                    PetPhysicsEngine.update(&engine.physicsState, dt: dt, surfaces: surfaces)
                    if engine.physicsState.surface != .airborne {
                        engine.currentAction = .idle
                        behaviorElapsed = 0
                    }
                default:
                    break
                }

                // Remove expired particles
                engine.particles.removeAll { $0.isExpired }
            }
        }
    }

    // MARK: - Behavior Loop

    private func startBehaviorLoop() {
        behaviorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard !isDragging else { return }
                behaviorElapsed += 1.0

                if let forcedMood = PetTimeOfDayBehavior.suggestedMood(
                    lastInteraction: engine.pet.lastInteraction) {
                    engine.pet.mood = forcedMood
                }

                let nextAction = PetBehaviorController.nextBehavior(
                    current: engine.currentAction,
                    physics: engine.physicsState,
                    level: engine.pet.level,
                    elapsed: behaviorElapsed)

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
}
