import Foundation

/// Bridges a PeerDrop conversation to an AI CLI running in **headless** mode
/// (e.g. `claude -p`). Each inbound chat message spawns the agent with that
/// message as the prompt, captures its plain-text output, and emits it as a
/// single chat reply — so a full-screen TUI never has to be flattened into
/// chat bubbles (which loses its layout entirely).
///
/// Messages are processed serially on a private queue: one agent invocation at
/// a time, in arrival order — which also matches what `--continue` expects.
final class AgentBridge: MessageBridge {
    private let baseCommand: [String]
    private let permissionMode: String
    private let queue = DispatchQueue(label: "peerdrop.cli.agent")

    private let lock = NSLock()
    private var _current: Process?
    private var current: Process? {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); defer { lock.unlock() }; _current = newValue }
    }

    var onMessage: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    /// Fires `true` when an agent invocation starts and `false` when it ends —
    /// a seam for a future "thinking…" typing indicator.
    var onActivity: ((Bool) -> Void)?

    init(baseCommand: [String], permissionMode: String) {
        precondition(!baseCommand.isEmpty, "agent base command must not be empty")
        self.baseCommand = baseCommand
        self.permissionMode = permissionMode
    }

    /// The argv passed to `/usr/bin/env` for a given prompt. Pure, so it can be
    /// asserted without spawning the agent.
    static func arguments(for prompt: String, baseCommand: [String], permissionMode: String) -> [String] {
        baseCommand + ["-p", prompt,
                       "--continue",
                       "--output-format", "text",
                       "--permission-mode", permissionMode]
    }

    func start() {
        // Headless agents are request/response: nothing runs until a message
        // arrives. No banner, no idle process.
    }

    func send(_ line: String) {
        let prompt = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        queue.async { [weak self] in self?.run(prompt: prompt) }
    }

    private func run(prompt: String) {
        onActivity?(true)
        defer { onActivity?(false) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = Self.arguments(for: prompt, baseCommand: baseCommand, permissionMode: permissionMode)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            onMessage?("⚠️ couldn't start agent: \(error.localizedDescription)")
            return
        }
        current = proc
        // readDataToEndOfFile drains the pipe as the agent writes, so a large
        // reply can't deadlock on a full pipe buffer; it returns at EOF (exit).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        current = nil

        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if proc.terminationStatus != 0 {
            onMessage?("⚠️ agent exited \(proc.terminationStatus)" + (text.isEmpty ? "" : ":\n\(text)"))
        } else if !text.isEmpty {
            onMessage?(text)
        }
    }

    func terminate() {
        // Not queue-bound: the queue is blocked inside run() while the agent
        // runs, so killing it has to come from the caller's thread directly.
        current?.terminate()
    }
}
