import Foundation

@MainActor
class PetAnimationController: ObservableObject {
    @Published private(set) var currentFrame: Int = 0

    /// Per-action frame rate. v4 hard-coded 6 fps; v5 sets it via
    /// setAction(_:frameCount:fps:) to match the action's metadata
    /// (walk = 6 fps, idle = 2 fps).
    private(set) var fps: Int = 6
    private(set) var totalFrames: Int = 2
    private(set) var currentAction: PetAction = .idle
    private var timer: Timer?

    /// v4-era constant. Retained as a computed proxy so legacy callers and
    /// tests reading `frameRate` still see something sensible. v5 callers
    /// should read `fps` instead.
    var frameRate: TimeInterval { 1.0 / Double(max(fps, 1)) }

    /// Whether the animation timer is currently scheduled.
    /// Used by tests and by scene-phase pause/resume logic to verify state.
    var isAnimating: Bool { timer != nil }

    /// v5 entry — sets action with per-action fps and auto-starts the timer
    /// so production callers don't have to remember to call startAnimation().
    /// Same-action calls are no-ops to preserve in-flight frameIndex on
    /// direction changes (PetEngine.tick rebinds on action transitions, not
    /// direction transitions).
    func setAction(_ action: PetAction, frameCount: Int, fps: Int) {
        guard action != currentAction else { return }
        currentAction = action
        totalFrames = max(1, frameCount)
        self.fps = max(1, fps)
        currentFrame = 0
        restartTimer()
    }

    /// v4 legacy entry — no fps update, no auto-start. Kept so v4 tests + any
    /// existing call sites continue to work unchanged. v5 production code
    /// should use the 3-arg overload above.
    func setAction(_ action: PetAction, frameCount: Int) {
        guard action != currentAction || frameCount != totalFrames else { return }
        currentAction = action
        totalFrames = max(1, frameCount)
        currentFrame = 0
    }

    func advanceFrame() {
        currentFrame = (currentFrame + 1) % totalFrames
    }

    func startAnimation() {
        restartTimer()
    }

    func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    /// v5 alias for startAnimation — matches the PetEngine integration call
    /// site naming in the design doc (pause on app background, resume on
    /// foreground). Production code should prefer pause()/resume() since the
    /// semantics are clearer than start/stop.
    func pause() { stopAnimation() }
    func resume() { restartTimer() }

    private func restartTimer() {
        timer?.invalidate()
        let interval = 1.0 / Double(max(fps, 1))
        let newTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] firingTimer in
            Task { @MainActor [weak self] in
                self?.timerTick(from: firingTimer)
            }
        }
        timer = newTimer
    }

    /// Called by the active Timer's callback. Gates on timer identity so a
    /// stale Task scheduled by a now-invalidated timer doesn't advance the
    /// frame after pause()/stopAnimation(). Without this guard, a Timer that
    /// fires microseconds before pause() can race ahead because @MainActor
    /// serializes pause() and the in-flight Task — the Task wins if it was
    /// queued first, advancing one extra frame past pause.
    private func timerTick(from firingTimer: Timer) {
        guard timer === firingTimer else { return }
        advanceFrame()
    }
}
