import SwiftUI

struct GuestPetView: View {
    let greeting: PetGreeting
    @State private var position: CGPoint
    @State private var renderedImage: CGImage?
    /// View-lifetime renderer instance — lets PetRendererV3.lastComposite
    /// memoization survive across renders. Per-call allocation lost the memo
    /// (the SpriteService.shared cache still helped, but the composite step
    /// re-ran every tick).
    @State private var renderer = PetRendererV3()

    init(greeting: PetGreeting, initialPosition: CGPoint) {
        self.greeting = greeting
        self._position = State(initialValue: initialPosition)
    }

    var body: some View {
        SpriteImageView(image: renderedImage, displaySize: 64)
            .opacity(0.8)
            .position(position)
            .task { await renderSnapshot() }
    }

    /// Renders the peer's pet via the v4.0 PNG pipeline. The peer's
    /// (genome, level, mood, direction) is fixed for the lifetime of this
    /// view (greeting is `let`), so a single render at .task time is enough
    /// — the previous 0.5 s timer was a v3.x carryover for the legacy
    /// `frame: Int` cycle that this view no longer has.
    @MainActor
    private func renderSnapshot() async {
        renderedImage = try? await renderer.render(
            genome: greeting.genome,
            level: greeting.level,
            mood: greeting.mood,
            direction: .east)
    }
}
