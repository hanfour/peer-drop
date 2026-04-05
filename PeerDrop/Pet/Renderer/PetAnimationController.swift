import Foundation

@MainActor
class PetAnimationController: ObservableObject {
    @Published var currentFrame: Int = 0
    let frameRate: TimeInterval = 0.5 // 2 FPS

    private var timer: Timer?
    private var frameCount: Int = 2

    func startAnimation(frameCount: Int = 2) {
        stopAnimation()
        self.frameCount = frameCount
        currentFrame = 0
        timer = Timer.scheduledTimer(withTimeInterval: frameRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentFrame = (self.currentFrame + 1) % self.frameCount
            }
        }
    }

    func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
