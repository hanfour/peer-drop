import Foundation
import Darwin

/// A child process attached to a PTY, exposing RAW byte I/O (no ANSI stripping,
/// no line buffering). The terminal-faithful core extracted from ProcessBridge.
public final class PTYProcess {
    private let command: [String]
    /// Optional environment for the child. `nil` inherits the parent's
    /// environment unchanged (the webterm path relies on this default).
    private let environment: [String: String]?
    private var process: Process?
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let writeQueue = DispatchQueue(label: "peerdrop.pty.write")

    /// Raw PTY output bytes. Fires on an arbitrary queue.
    public var onBytes: ((Data) -> Void)?
    /// Child exit, with status. Fires on an arbitrary queue.
    public var onExit: ((Int32) -> Void)?

    public init(command: [String], environment: [String: String]? = nil) {
        precondition(!command.isEmpty, "command must not be empty")
        self.command = command
        self.environment = environment
    }

    /// Whether the child process is currently running.
    public var isRunning: Bool { process?.isRunning ?? false }

    public func start() {
        guard !(process?.isRunning ?? false) else { return }
        readSource?.cancel(); readSource = nil; masterFD = -1

        var master: Int32 = 0, slave: Int32 = 0
        var term = termios()
        cfmakeraw(&term)
        guard openpty(&master, &slave, nil, &term, nil) == 0 else { onExit?(-1); return }
        masterFD = master

        let proc = Process()
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.executableURL = URL(fileURLWithPath: command[0])
        proc.arguments = Array(command.dropFirst())
        if let environment { proc.environment = environment }
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle
        proc.terminationHandler = { [weak self] p in self?.onExit?(p.terminationStatus) }
        self.process = proc

        let capturedMaster = master
        let source = DispatchSource.makeReadSource(fileDescriptor: master)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(self.masterFD, &buf, buf.count)
            if n > 0 { self.onBytes?(Data(buf[0..<n])) } else { self.readSource?.cancel() }
        }
        source.setCancelHandler { close(capturedMaster) }
        readSource = source
        source.resume()

        do { try proc.run(); close(slave) } catch { onExit?(-1) }
    }

    /// Write raw bytes to the PTY (key input passthrough — no newline appended).
    public func writeBytes(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            _ = data.withUnsafeBytes { write(self.masterFD, $0.baseAddress, $0.count) }
        }
    }

    /// Set the PTY window size so the child's terminal layout matches the browser.
    public func resize(cols: UInt16, rows: UInt16) {
        writeQueue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.masterFD, UInt(TIOCSWINSZ), &ws)
        }
    }

    public func terminate() {
        if process?.isRunning ?? false { process?.terminate() }
        masterFD = -1
        readSource?.cancel()
    }
}
