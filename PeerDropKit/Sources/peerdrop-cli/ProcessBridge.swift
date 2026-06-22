import Foundation
import PeerDropPTY

/// Wraps a child process in a PTY and bridges its terminal I/O to chat:
/// PTY output → OutputSegmenter (→ chat messages); inbound text → PTY input.
///
/// The raw PTY plumbing (openpty, DispatchSourceRead, fd lifetime) lives in
/// PTYProcess; this layer adds the chat-mode contract (line-based send, idle-flush
/// segmentation, ANSI stripping) on top.
final class ProcessBridge {
    private let command: [String]
    private let environment: [String: String]?
    private let idle: DispatchTimeInterval
    /// Lazily created so `onMessage` can be set after `init` but before
    /// `start()`. The first access (from the PTY onBytes callback) is
    /// always after the caller has assigned `onMessage`.
    private lazy var segmenter = OutputSegmenter(idle: idle, emit: { [weak self] text in
        self?.onMessage?(text)
    })
    /// The underlying PTY process. Replaced on every `start()` so the bridge
    /// is restart-safe (a PTYProcess / Process cannot be re-run once started).
    private var pty: PTYProcess?

    /// Set this before calling `start()`. Called on an arbitrary dispatch
    /// queue (the OutputSegmenter timer queue); callers that update UI or
    /// actor-isolated state must hop to their own actor/queue inside this closure.
    var onMessage: ((String) -> Void)?

    /// Called on an arbitrary queue (the Process termination queue).
    /// Callers that update UI or actor-isolated state must hop to their own
    /// actor/queue inside this closure.
    var onExit: ((Int32) -> Void)?

    init(command: [String],
         environment: [String: String]? = nil,
         idle: DispatchTimeInterval = .milliseconds(350)) {
        precondition(!command.isEmpty, "command must not be empty")
        self.command = command
        self.environment = environment
        self.idle = idle
    }

    func start() {
        // Guard against double-start while already running.
        if let existing = pty, existing.isRunning { return }

        let p = PTYProcess(command: command, environment: environment)
        p.onBytes = { [weak self] data in
            self?.segmenter.ingest(data)
        }
        p.onExit = { [weak self] code in
            self?.segmenter.flush()
            self?.onExit?(code)
        }
        pty = p
        p.start()
    }

    /// Writes `line` (plus a newline) to the child's PTY input.
    /// This is the chat-mode line contract; the raw PTY byte layer lives in PTYProcess.
    func send(_ line: String) {
        pty?.writeBytes(Data((line + "\n").utf8))
    }

    func terminate() {
        pty?.terminate()
    }
}
