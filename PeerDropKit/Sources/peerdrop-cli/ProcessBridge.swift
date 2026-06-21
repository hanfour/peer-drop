import Foundation
import Darwin

/// Wraps a child process in a PTY and bridges its terminal I/O to chat:
/// PTY output → OutputSegmenter (→ chat messages); inbound text → PTY input.
final class ProcessBridge {
    private let command: [String]
    private let idle: DispatchTimeInterval
    /// Lazily created so `onMessage` can be set after `init` but before
    /// `start()`. The first access (from the read source event handler) is
    /// always after the caller has assigned `onMessage`.
    private lazy var segmenter = OutputSegmenter(idle: idle, emit: { [weak self] text in
        self?.onMessage?(text)
    })
    /// Replaced with a fresh instance on every `start()` call so the bridge
    /// is restart-safe (a `Process` cannot be re-run once it has been run).
    private var process: Process?
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let writeQueue = DispatchQueue(label: "peerdrop.cli.bridge.write")

    /// Set this before calling `start()`. Called on an arbitrary dispatch
    /// queue (the OutputSegmenter timer queue); callers that update UI or
    /// actor-isolated state must hop to their own actor/queue inside this closure.
    var onMessage: ((String) -> Void)?

    /// Called on an arbitrary queue (the Process termination queue).
    /// Callers that update UI or actor-isolated state must hop to their own
    /// actor/queue inside this closure.
    var onExit: ((Int32) -> Void)?

    init(command: [String],
         idle: DispatchTimeInterval = .milliseconds(350)) {
        precondition(!command.isEmpty, "command must not be empty")
        self.command = command
        self.idle = idle
    }

    func start() {
        // Guard against double-start while already running.
        guard !(process?.isRunning ?? false) else { return }

        // Tear down any lingering read source from a previous run before
        // creating a new one (start() is normally only called after onExit,
        // so this is belt-and-suspenders).
        readSource?.cancel()
        readSource = nil
        // masterFD will be set via the cancel handler when the old source
        // drains; reset it here so send() rejects stale writes immediately.
        masterFD = -1

        var master: Int32 = 0
        var slave: Int32 = 0
        var term = termios()
        cfmakeraw(&term)
        // cfmakeraw already clears ECHO; this is explicit for clarity.
        term.c_lflag &= ~tcflag_t(ECHO)
        guard openpty(&master, &slave, nil, &term, nil) == 0 else {
            onExit?(-1); return
        }
        masterFD = master

        // closeOnDealloc: false — we manually close(slave) after process.run()
        // so we own the lifetime explicitly. Double-close fix: NOT using
        // closeOnDealloc:true here, which would close slave again on dealloc.
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

        // Fresh Process instance every start() — a Process cannot be re-run.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command[0])
        proc.arguments = Array(command.dropFirst())
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle
        proc.terminationHandler = { [weak self] p in
            self?.segmenter.flush()
            self?.onExit?(p.terminationStatus)
        }
        process = proc

        let source = DispatchSource.makeReadSource(fileDescriptor: master)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(self.masterFD, &buf, buf.count)
            if n > 0 {
                self.segmenter.ingest(Data(buf[0..<n]))
            } else {
                // EOF or error — stop the read loop.
                // cancel() triggers the cancel handler, which closes master.
                self.readSource?.cancel()
            }
        }
        // Cancel handler owns the master fd close: this guarantees the fd is
        // closed exactly once, AFTER the source has stopped delivering events,
        // eliminating the race between terminate() and the event handler.
        let capturedMaster = master
        source.setCancelHandler { close(capturedMaster) }
        readSource = source
        source.resume()

        do {
            try proc.run()
            // Parent closes its copy of the slave end after the child inherits
            // it. This lets the master side see EOF when the child exits.
            close(slave)
        } catch {
            onExit?(-1)
        }
    }

    /// Writes `line` (plus a newline) to the child's PTY input.
    /// Always reads the current `masterFD` via `self` — never a value captured
    /// at call-site — so there is no stale-fd hazard after a restart.
    func send(_ line: String) {
        writeQueue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            let data = Array((line + "\n").utf8)
            _ = data.withUnsafeBytes { write(self.masterFD, $0.baseAddress, $0.count) }
        }
    }

    func terminate() {
        if process?.isRunning == true { process?.terminate() }
        // Invalidate masterFD first so send() rejects any in-flight writes.
        masterFD = -1
        // cancel() stops event delivery and triggers the cancel handler,
        // which performs the close(master). No manual close(masterFD) here.
        readSource?.cancel()
        readSource = nil
    }
}
