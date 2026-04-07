import Foundation

@MainActor
class PetAnimationController: ObservableObject {
    @Published var currentFrame: Int = 0

    let frameRate: TimeInterval = 1.0 / 6.0  // 6 FPS
    private(set) var totalFrames: Int = 2
    private var currentAction: PetAction = .idle
    private var timer: Timer?

    func setAction(_ action: PetAction, frameCount: Int) {
        guard action != currentAction || frameCount != totalFrames else { return }
        currentAction = action
        totalFrames = max(1, frameCount)
        currentFrame = 0
    }

    func advanceFrame() {
        currentFrame = (currentFrame + 1) % totalFrames
    }

    func startAnimation(frameCount: Int = 2) {
        stopAnimation()
        totalFrames = max(1, frameCount)
        currentFrame = 0
        timer = Timer.scheduledTimer(withTimeInterval: frameRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceFrame()
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
