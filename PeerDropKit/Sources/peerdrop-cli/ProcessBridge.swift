import Foundation
import Darwin

/// Wraps a child process in a PTY and bridges its terminal I/O to chat:
/// PTY output → OutputSegmenter (→ chat messages); inbound text → PTY input.
final class ProcessBridge {
    private let command: [String]
    private let segmenter: OutputSegmenter
    private let process = Process()
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let writeQueue = DispatchQueue(label: "peerdrop.cli.bridge.write")

    var onExit: ((Int32) -> Void)?

    init(command: [String],
         idle: DispatchTimeInterval = .milliseconds(350),
         onMessage: @escaping (String) -> Void) throws {
        precondition(!command.isEmpty, "command must not be empty")
        self.command = command
        self.segmenter = OutputSegmenter(idle: idle, emit: onMessage)
    }

    func start() {
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
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        process.terminationHandler = { [weak self] proc in
            self?.segmenter.flush()
            self?.onExit?(proc.terminationStatus)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: master)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(self.masterFD, &buf, buf.count)
            if n > 0 {
                self.segmenter.ingest(Data(buf[0..<n]))
            } else {
                // EOF or error — stop the read loop.
                self.readSource?.cancel()
            }
        }
        readSource = source
        source.resume()

        do {
            try process.run()
            // Parent closes its copy of the slave end after the child inherits
            // it. This lets the master side see EOF when the child exits.
            close(slave)
        } catch {
            onExit?(-1)
        }
    }

    func send(_ line: String) {
        writeQueue.async { [masterFD] in
            guard masterFD >= 0 else { return }
            let data = Array((line + "\n").utf8)
            _ = data.withUnsafeBytes { write(masterFD, $0.baseAddress, $0.count) }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        readSource?.cancel()
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
    }
}
