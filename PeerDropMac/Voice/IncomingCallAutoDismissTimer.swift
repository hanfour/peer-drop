#if canImport(AppKit)
import Foundation

/// 30s auto-dismiss timer wrapper for `MacIncomingCallPanel`.
///
/// Backed by `Task.sleep`. `cancel()` is idempotent and safe to call
/// from cleanup paths. Restarting via `start(...)` cancels the prior
/// task — no overlapping timers.
@MainActor
final class IncomingCallAutoDismissTimer {
    private var task: Task<Void, Never>?

    func start(duration: TimeInterval = 30, onFire: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            onFire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
#endif
