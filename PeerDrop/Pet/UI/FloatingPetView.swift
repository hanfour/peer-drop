import SwiftUI

struct FloatingPetView: View {
    @ObservedObject var engine: PetEngine
    @State private var isDragging = false
    @State private var lastDragPositions: [(CGPoint, Date)] = []
    @State private var showInteractionPanel = false
    @State private var displayLink: CADisplayLink?

    var body: some View {
        ZStack {
            // Poops on screen
            ForEach(engine.poopState.poops) { poop in
                Text("\u{1F4A9}")
                    .font(.system(size: 20))
                    .position(poop.position)
                    .onTapGesture { engine.cleanPoop(id: poop.id) }
            }

            // Particles
            ForEach(engine.particles) { particle in
                PetParticleView(particle: particle)
                    .position(particle.position)
            }

            // Pet sprite
            SpriteImageView(image: engine.renderedImage, displaySize: 128)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

            // Dialogue bubble
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
                    isDragging = true
                    engine.physicsState.position = value.location
                    engine.physicsState.surface = .airborne
                    trackDragVelocity(value.location)
                    engine.currentAction = .pickedUp
                }
                .onEnded { _ in
                    isDragging = false
                    let velocity = calculateThrowVelocity()
                    PetPhysicsEngine.applyThrow(&engine.physicsState, velocity: velocity)
                    engine.currentAction = .thrown
                    engine.handleInteraction(.tap)
                }
        )
        .onTapGesture { engine.handleInteraction(.tap) }
        .onLongPressGesture { showInteractionPanel = true }
        .sheet(isPresented: $showInteractionPanel) {
            PetInteractionView(engine: engine)
        }
        .accessibilityIdentifier("floating-pet")
        .accessibilityLabel("Pet")
        .onAppear { startPhysicsLoop() }
        .onDisappear { stopPhysicsLoop() }
    }

    // MARK: - Physics Loop

    private func startPhysicsLoop() {
        let link = CADisplayLink(target: PhysicsTarget(update: physicsStep),
                                 selector: #selector(PhysicsTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopPhysicsLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func physicsStep() {
        guard !isDragging else { return }
        let dt: CGFloat = 1.0 / 60.0
        let surfaces = currentScreenSurfaces()

        switch engine.physicsState.surface {
        case .airborne:
            PetPhysicsEngine.update(&engine.physicsState, dt: dt, surfaces: surfaces)
            // If landed, return to idle
            if engine.physicsState.surface == .ground {
                engine.currentAction = .idle
            }
        case .ground:
            if engine.currentAction == .walking {
                let dir: PetPhysicsEngine.HorizontalDirection = engine.physicsState.facingRight ? .right : .left
                PetPhysicsEngine.applyWalk(&engine.physicsState, direction: dir, speed: 30, dt: dt, surfaces: surfaces)
            }
        case .leftWall, .rightWall:
            if engine.currentAction == .climb {
                PetPhysicsEngine.applyClimb(&engine.physicsState, speed: 20, dt: dt, surfaces: surfaces)
            }
        default:
            break
        }
    }

    private func currentScreenSurfaces() -> ScreenSurfaces {
        let screen = UIScreen.main.bounds
        let safeArea = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
            .first ?? .zero
        return ScreenSurfaces(
            ground: screen.height - safeArea.bottom - 16,
            ceiling: safeArea.top,
            leftWall: 0,
            rightWall: screen.width,
            dynamicIslandRect: CGRect(x: screen.width / 2 - 63, y: 0, width: 126, height: 37)
        )
    }

    // MARK: - Drag Velocity Tracking

    private func trackDragVelocity(_ position: CGPoint) {
        lastDragPositions.append((position, Date()))
        if lastDragPositions.count > 3 { lastDragPositions.removeFirst() }
    }

    private func calculateThrowVelocity() -> CGVector {
        guard lastDragPositions.count >= 2 else { return .zero }
        let first = lastDragPositions.first!
        let last = lastDragPositions.last!
        let dt = last.1.timeIntervalSince(first.1)
        guard dt > 0.01 else { return .zero }
        lastDragPositions.removeAll()
        return CGVector(
            dx: (last.0.x - first.0.x) / dt,
            dy: (last.0.y - first.0.y) / dt
        )
    }
}

// CADisplayLink target (avoids retain cycle)
private class PhysicsTarget {
    let update: () -> Void
    init(update: @escaping () -> Void) { self.update = update }
    @objc func tick() { update() }
}
