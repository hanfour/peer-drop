import SwiftUI

struct GuestPetView: View {
    let greeting: PetGreeting
    @State private var position: CGPoint
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
            .task { await renderSnapshot() }
            .onReceive(timer) { _ in
                Task { await renderSnapshot() }
            }
    }

    /// Renders the peer's pet directly via the v4.0 PNG pipeline. Each call
    /// hits the SpriteService cache (warmed by the host app's own renders),
    /// so per-tick cost after first render is sub-millisecond.
    @MainActor
    private func renderSnapshot() async {
        let renderer = PetRendererV3()
        renderedImage = try? await renderer.render(
            genome: greeting.genome,
            level: greeting.level,
            mood: greeting.mood,
            direction: .east)
    }
}
