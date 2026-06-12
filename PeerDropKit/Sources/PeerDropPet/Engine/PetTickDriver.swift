import Foundation

/// Hostless animation clock for platforms without a CADisplayLink host.
///
/// PetAnimationController deliberately has no internal timer (v5.1 deferred
/// design #4) — on iOS the FloatingPetView CADisplayLink feeds
/// `advance(dt:)` so physics and animation share one time source. The Mac
/// app has no floating-pet overlay and therefore had no tick source at all:
/// `animator.$currentFrame` never fired, `PetEngine.renderedImage` never
/// republished, and the sidebar/menu-bar sprite froze on frame 0
/// (2026-06-12 regression report "寵物系統異常").
///
/// The driver is a thin `Task`-based clock (not `Timer`) so it needs no
/// RunLoop, stays on the main actor with the animator, and tears down
/// cleanly via cooperative cancellation. The animator reference is weak —
/// the engine owns the animator; the driver must never extend its lifetime.
@MainActor
public final class PetTickDriver {

    private weak var animator: PetAnimationController?
    private var tickTask: Task<Void, Never>?

    /// Tick interval. ~30 Hz comfortably oversamples the fastest sprite
    /// action (walk = 6 fps); the animator's dt accumulator owns the actual
    /// frame pacing, so the driver cadence only bounds latency, not speed.
    private let tickInterval: Duration

    /// Test seam: number of live clock tasks (0 or 1). `start()` twice must
    /// not stack a second clock — that would double the effective fps.
    public var activeTickTaskCount: Int { tickTask == nil ? 0 : 1 }

    public init(animator: PetAnimationController, tickInterval: Duration = .milliseconds(33)) {
        self.animator = animator
        self.tickInterval = tickInterval
    }

    public func start() {
        guard tickTask == nil else { return }
        let interval = tickInterval
        tickTask = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                let now = ContinuousClock.now
                let dt = last.duration(to: now)
                last = now
                // Feed real elapsed wall-clock (not the nominal interval) so
                // frame pacing stays correct under scheduler delay, exactly
                // like the CADisplayLink host does on iOS.
                let dtSeconds = Double(dt.components.seconds)
                    + Double(dt.components.attoseconds) / 1e18
                self?.animator?.advance(dt: dtSeconds)
            }
        }
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    deinit {
        tickTask?.cancel()
    }
}
