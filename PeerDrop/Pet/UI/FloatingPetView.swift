import SwiftUI

struct FloatingPetView: View {
    @ObservedObject var engine: PetEngine
    @State private var position = CGPoint(x: 60, y: 200)
    @State private var isDragging = false
    @State private var showInteractionPanel = false
    @State private var wanderTimer: Timer?

    var body: some View {
        ZStack {
            PixelView(grid: engine.renderedGrid, displaySize: 64)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            if let dialogue = engine.currentDialogue {
                PetBubbleView(text: dialogue)
                    .offset(y: -44)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .position(position)
        .gesture(DragGesture()
            .onChanged { value in isDragging = true; position = value.location }
            .onEnded { _ in isDragging = false; engine.handleInteraction(.tap) })
        .onTapGesture { engine.handleInteraction(.tap) }
        .onLongPressGesture { showInteractionPanel = true }
        .sheet(isPresented: $showInteractionPanel) {
            PetInteractionView(engine: engine)
        }
        .accessibilityIdentifier("floating-pet")
        .accessibilityLabel("Pet")
        .onAppear { startWandering() }
        .onDisappear { wanderTimer?.invalidate() }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: position)
    }

    private func startWandering() {
        wanderTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                guard !isDragging, engine.currentAction == .idle || engine.currentAction == .walking else { return }
                let screen = UIScreen.main.bounds
                let margin: CGFloat = 40
                let edge = Int.random(in: 0...3)
                let target: CGPoint
                switch edge {
                case 0: target = CGPoint(x: .random(in: margin...(screen.width - margin)), y: margin + 50)
                case 1: target = CGPoint(x: .random(in: margin...(screen.width - margin)), y: screen.height - margin - 50)
                case 2: target = CGPoint(x: margin, y: .random(in: 100...(screen.height - 100)))
                default: target = CGPoint(x: screen.width - margin, y: .random(in: 100...(screen.height - 100)))
                }
                withAnimation(.linear(duration: 3.0)) { position = target }
                engine.currentAction = .walking
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                engine.currentAction = .idle
            }
        }
    }
}
