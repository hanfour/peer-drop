import Foundation
import PeerDropPTY

/// Thin wrapper over the `tmux` CLI for session lifecycle.
enum TmuxControl {
    /// Namespace prefix that CALLERS (e.g. SessionManager) prepend to a preset id
    /// to form the tmux session name. createIfNeeded/kill take the full id as-is.
    static let prefix = "webterm-"

    @discardableResult
    private static func tmux(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["tmux"] + args
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    static func exists(_ id: String) -> Bool {
        ((try? tmux(["has-session", "-t", id])) ?? 1) == 0
    }

    static func createIfNeeded(id: String, command: String, cwd: String?) throws {
        guard !exists(id) else { return }
        var args = ["new-session", "-d", "-s", id]
        if let cwd { args += ["-c", cwd] }
        args += ["bash", "-lc", command]
        // Use tmux's ';' command separator (its own argv element) so new-session and
        // set-option run in a single tmux invocation — no race if the command exits fast.
        args += [";", "set-option", "-t", id, "remain-on-exit", "on"]
        _ = try tmux(args)
    }

    @discardableResult
    static func kill(_ id: String) throws -> Int32 { try tmux(["kill-session", "-t", id]) }
}

/// One tmux-attached PTY. Broadcasts raw output to all clients; fans in input.
public final class TerminalSession {
    public typealias ClientID = UUID
    private let id: String
    private var pty: PTYProcess?
    private var clients: [ClientID: (Data) -> Void] = [:]
    private let lock = NSLock()
    /// Set to `true` after the first successful `start()` call.
    /// Subsequent calls are no-ops so multiple WS connections sharing
    /// the same cached TerminalSession do not spawn extra attach PTYs.
    private var isStarted: Bool = false

    public init(id: String) { self.id = id }

    public func start() {
        lock.lock()
        guard !isStarted else { lock.unlock(); return }
        isStarted = true
        lock.unlock()
        let pty = PTYProcess(command: ["/usr/bin/env", "tmux", "attach-session", "-t", id])
        pty.onBytes = { [weak self] data in
            guard let self else { return }
            self.lock.lock(); let sinks = Array(self.clients.values); self.lock.unlock()
            for sink in sinks { sink(data) }
        }
        self.pty = pty
        pty.start()
    }

    @discardableResult
    public func addClient(_ sink: @escaping (Data) -> Void) -> ClientID {
        let cid = UUID(); lock.lock(); clients[cid] = sink; lock.unlock(); return cid
    }

    public func removeClient(_ cid: ClientID) { lock.lock(); clients[cid] = nil; lock.unlock() }

    public func write(_ data: Data) { pty?.writeBytes(data) }
    public func resize(cols: UInt16, rows: UInt16) { pty?.resize(cols: cols, rows: rows) }

    /// Detach the local PTY from the tmux session. The tmux session itself keeps running.
    public func detach() { pty?.terminate(); pty = nil }
}
