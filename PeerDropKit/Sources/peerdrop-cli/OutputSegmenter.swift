import Foundation

/// Converts a continuous PTY byte stream into discrete chat messages using an
/// idle-flush heuristic: emit the accumulated (ANSI-stripped) text after the
/// stream goes quiet for `idle`, or immediately if the buffer exceeds `cap`.
final class OutputSegmenter {
    private let idle: DispatchTimeInterval
    private let cap: Int
    private let emit: (String) -> Void
    private let queue = DispatchQueue(label: "peerdrop.cli.segmenter")
    private var buffer = Data()
    private var pending: DispatchWorkItem?

    init(idle: DispatchTimeInterval = .milliseconds(350),
         cap: Int = 256 * 1024,
         emit: @escaping (String) -> Void) {
        self.idle = idle
        self.cap = cap
        self.emit = emit
    }

    func ingest(_ data: Data) {
        queue.sync {
            buffer.append(data)
            if buffer.count >= cap {
                flushLocked()
            } else {
                scheduleLocked()
            }
        }
    }

    func flush() { queue.sync { flushLocked() } }

    private func scheduleLocked() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Already executing on `queue` via asyncAfter — call flushLocked
            // directly. Do NOT re-enter queue.sync here; that would deadlock
            // on a serial queue.
            self?.flushLocked()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + idle, execute: work)
    }

    private func flushLocked() {
        pending?.cancel()
        pending = nil
        guard !buffer.isEmpty else { return }
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        let stripped = AnsiStripper.strip(text)
        guard !stripped.isEmpty else { return }
        emit(stripped)
    }
}
