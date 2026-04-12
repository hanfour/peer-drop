import SwiftUI

struct GuestPetView: View {
    let greeting: PetGreeting
    @State private var position: CGPoint
    @State private var frame: Int = 0
    @State private var renderedImage: CGImage?
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(greeting: PetGreeting, initialPosition: CGPoint) {
        self.greeting = greeting
        self._position = State(initialValue: initialPosition)
    }

    var body: some View {
        SpriteImageView(image: renderedImage, displaySize: 64)
            .opacity(0.8)
            .position(position)
            .onAppear { renderSnapshot() }
            .onReceive(timer) { _ in
                frame = (frame + 1) % 2
                renderSnapshot()
            }
    }

    private func renderSnapshot() {
        renderedImage = PetSnapshotRenderer.render(
            body: greeting.genome.body,
            level: greeting.level,
            mood: greeting.mood,
            eyes: greeting.genome.eyes,
            pattern: greeting.genome.pattern,
            paletteIndex: greeting.genome.paletteIndex)
    }
}
