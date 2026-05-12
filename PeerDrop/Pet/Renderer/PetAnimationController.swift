import Foundation

/// Drives sprite animation frame advancement. As of v5.1 (deferred design #4)
/// the controller has no internal clock — `advance(dt:)` is called from the
/// host's CADisplayLink tick (FloatingPetView.physicsStep), making physics and
/// animation share a single time source. dt accumulates until `1 / fps`, then
/// the frame index advances and the accumulator carries the remainder.
///
/// The v4-era Timer path is gone; with it the `timer === firingTimer` race-fix
/// (Task @MainActor scheduled callback vs. pause()) is no longer needed —
/// pause/resume now just toggles a flag that `advance(dt:)` checks early-out.
@MainActor
class PetAnimationController: ObservableObject {
    @Published private(set) var currentFrame: Int = 0

    /// Per-action frame rate. v4 hard-coded 6 fps; v5 sets it via
    /// setAction(_:frameCount:fps:) to match the action's metadata
    /// (walk = 6 fps, idle = 2 fps).
    private(set) var fps: Int = 6
    private(set) var totalFrames: Int = 2
    private(set) var currentAction: PetAction = .idle

    /// True while the controller is suspended — `advance(dt:)` returns early.
    /// Default `true` so a freshly-constructed controller doesn't tick until
    /// the host explicitly opts in via `startAnimation()` or
    /// `setAction(_:frameCount:fps:)`.
    private var paused: Bool = true

    /// Accumulated dt since the last frame boundary. When this exceeds
    /// `1 / fps`, the frame advances and the excess carries to the next tick.
    /// Cleared on pause + action change so resume / setAction don't inherit
    /// the previous action's stale debt.
    private var accumulatedDt: TimeInterval = 0

    /// v4-era constant. Retained as a computed proxy so legacy callers and
    /// tests reading `frameRate` still see something sensible. v5 callers
    /// should read `fps` instead.
    var frameRate: TimeInterval { 1.0 / Double(max(fps, 1)) }

    /// Whether the controller is actively progressing frames (i.e. not paused).
    /// Used by tests and by scene-phase pause/resume logic to verify state.
    var isAnimating: Bool { !paused }

    /// v5 entry — sets action with per-action fps and unpauses the controller
    /// so production callers don't have to remember a separate "start" call.
    /// Same-action calls are no-ops to preserve in-flight frameIndex on
    /// direction changes (PetEngine.tick rebinds on action transitions, not
    /// direction transitions).
    func setAction(_ action: PetAction, frameCount: Int, fps: Int) {
        guard action != currentAction else { return }
        currentAction = action
        totalFrames = max(1, frameCount)
        self.fps = max(1, fps)
        currentFrame = 0
        accumulatedDt = 0
        paused = false
    }

    /// v4 legacy entry — no fps update, no unpause. Kept so v4 tests + any
    /// existing call sites continue to work unchanged. v5 production code
    /// should use the 3-arg overload above.
    func setAction(_ action: PetAction, frameCount: Int) {
        guard action != currentAction || frameCount != totalFrames else { return }
        currentAction = action
        totalFrames = max(1, frameCount)
        currentFrame = 0
        accumulatedDt = 0
    }

    /// Manually bump the frame index by one. Kept for v4 tests + any host
    /// that wants to step the animation without a delta-time accumulator.
    /// Production v5 should let `advance(dt:)` handle frame progression.
    func advanceFrame() {
        currentFrame = (currentFrame + 1) % totalFrames
    }

    /// Apply elapsed time. Called from the host CADisplayLink tick. Accumulates
    /// dt until at least one frame interval has passed, then advances the
    /// frame (and wraps via modulo `totalFrames`). At extreme throttle (slow
    /// CADisplayLink, e.g. thermal pressure) multiple frames can advance in
    /// one call, keeping animation in sync with wall-clock rather than lagging
    /// behind.
    ///
    /// No-op while paused — host doesn't need to gate the call site.
    func advance(dt: TimeInterval) {
        guard !paused, dt > 0 else { return }
        accumulatedDt += dt
        let frameInterval = 1.0 / Double(max(fps, 1))
        let epsilon = 1e-9
        guard accumulatedDt + epsilon >= frameInterval else { return }
        let stepsToAdvance = Int((accumulatedDt + epsilon) / frameInterval)
        accumulatedDt -= Double(stepsToAdvance) * frameInterval
        currentFrame = (currentFrame + stepsToAdvance) % max(totalFrames, 1)
    }

    func startAnimation() {
        paused = false
        accumulatedDt = 0
    }

    func stopAnimation() {
        paused = true
        accumulatedDt = 0
    }

    /// Semantically clearer aliases for scene-phase wiring.
    func pause()  { stopAnimation() }
    func resume() { startAnimation() }
}
