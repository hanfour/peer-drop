import SwiftUI

struct GuestPetView: View {
    let greeting: PetGreeting
    @State private var position: CGPoint
    @State private var frame: Int = 0
    private let renderer = PetRenderer()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(greeting: PetGreeting, initialPosition: CGPoint) {
        self.greeting = greeting
        self._position = State(initialValue: initialPosition)
    }

    var body: some View {
        PixelView(
            grid: renderer.render(genome: greeting.genome, level: greeting.level,
                                   mood: greeting.mood, animationFrame: frame),
            palette: PetPalettes.palette(for: greeting.genome),
            displaySize: 64
        )
        .opacity(0.8)
        .position(position)
        .onReceive(timer) { _ in frame = (frame + 1) % 2 }
    }
}
